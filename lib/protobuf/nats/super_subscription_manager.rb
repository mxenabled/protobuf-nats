require "active_support"
require "active_support/core_ext/class/subclasses"
require "concurrent"
require "protobuf/rpc/server"
require "protobuf/rpc/service"
require "protobuf/nats/thread_pool"
require "protobuf/nats/byte_bounded_queue"

module Protobuf
  module Nats
    class SuperSubscriptionManager
      def initialize(nats, &cb)
        # Central queue used by all subscriptions, bounded by both message count
        # and total bytes (see intake_queue_size / intake_queue_bytes). A byte-cap
        # drop is surfaced here as server.intake_bytes_dropped.
        @pending_queue = ::Protobuf::Nats::ByteBoundedQueue.new(
          intake_queue_size, intake_queue_bytes,
          :on_drop => lambda { |bytes| ::Protobuf::Nats.instrument("server.intake_bytes_dropped", bytes) }
        )
        @subscriptions = []
        @subscriptions_mutex = ::Mutex.new
        @nats = nats
        @callback = cb

        # Fan out the intake across several handler threads. A single thread is a
        # throughput ceiling on JRuby and lets one slow publish (ACK) inside the
        # callback head-of-line block every other subject. Each handler pops the
        # shared SizedQueue (thread-safe) independently.
        @pending_queue_handlers = handler_count.times.map { |i| spawn_handler(i) }

        ::Protobuf::Nats.instrument("server.subscription_handler_count", @pending_queue_handlers.size)
      end

      def logger
        ::Protobuf::Logging.logger
      end

      # Number of intake handler threads. On JRuby (true parallelism) fan out to
      # processor_count; on CRuby the GVL makes extra handlers pointless, so 1.
      # Overridable via env for tuning/tests. Mirrors ResponseMuxer#dispatcher_count.
      def handler_count
        @handler_count ||= begin
          default = ::RUBY_ENGINE == "jruby" ? ::Concurrent.processor_count : 1
          ::Protobuf::Nats.env_int("PB_NATS_SERVER_SUBSCRIPTION_HANDLERS", default, :min => 1)
        end
      end

      # Capacity of the shared intake queue. The nats-pure default (65,536)
      # lets requests queue far longer than any client's ack_timeout under
      # sustained load -- the client has retried or given up long before the
      # message is popped, so the backlog is mostly abandoned work. A smaller
      # size turns overload into prompt drops (and client retries with
      # backoff) instead of a deep stale backlog. Kept at the nats-pure
      # default for compatibility; tune down alongside
      # PB_NATS_SERVER_STALE_REQUEST_MS.
      def intake_queue_size
        @intake_queue_size ||= ::Protobuf::Nats.env_int("PB_NATS_SERVER_INTAKE_QUEUE_SIZE", ::NATS::IO::DEFAULT_SUB_PENDING_MSGS_LIMIT, :min => 1)
      end

      # Byte ceiling for the shared intake queue -- the aggregate-heap bound the
      # message count alone can't give (65,536 large requests is a lot of heap).
      # Bounds resident bytes across ALL subscriptions; the ByteBoundedQueue drops
      # a message that would exceed it rather than block nats-pure's read thread.
      # Default 128 MiB: higher than the client muxer's 64 MiB because the server
      # fans requests across many handler threads and its count cap is higher too.
      DEFAULT_INTAKE_QUEUE_BYTES = 128 * 1024 * 1024 # 128MiB

      # Read once, in #initialize, so no memoization is needed.
      def intake_queue_bytes
        ::Protobuf::Nats.env_int("PB_NATS_SERVER_INTAKE_QUEUE_BYTES", DEFAULT_INTAKE_QUEUE_BYTES, :min => 1)
      end

      def queue_subscribe(name)
        logger.debug { "queue_subscribe(#{name})" }
        sub = @nats.subscribe(name, :queue => name)

        # Rationale on Protobuf::Nats.disable_subscription_byte_limit!.
        ::Protobuf::Nats.disable_subscription_byte_limit!(sub)

        # Create a subscription but reset the pending queue to use a central pending queue.
        existing_pending_queue = sub.pending_queue
        sub.pending_queue = @pending_queue

        # Align the slow-consumer message-count limit with the shared queue's
        # capacity. nats-pure's read thread only drops a message (SlowConsumer)
        # when pending_queue.size >= pending_msgs_limit -- otherwise it pushes.
        # With the sub's default limit (65,536) above a smaller tuned intake
        # queue, the drop check never fires and the push into the full
        # SizedQueue BLOCKS the connection's single read thread, stalling
        # PING/PONG and every other subject until a handler pops. limit ==
        # capacity makes the check trip exactly before the push would block, so
        # overload becomes prompt drops (and client NACK-style retries) as
        # intended.
        sub.pending_msgs_limit = intake_queue_size if sub.respond_to?(:pending_msgs_limit=)

        # Push all race-conditioned messages onto the pending queue.
        # Should address a potential race condition. Chances of the round-trip message to an
        # existing queue before this queue swap happens seems extremely low, but possible.
        migrated_count = 0
        max_migrations = 10000  # Safety limit

        while !existing_pending_queue.empty? && migrated_count < max_migrations
          # Non-blocking pop: another consumer could in theory drain it, so don't block.
          begin
            msg = existing_pending_queue.pop(true)
          rescue ThreadError
            break
          end

          # Push with a deadline (see push_with_deadline: no Timeout.timeout,
          # which corrupts the SizedQueue mutex on JRuby).
          if push_with_deadline(msg, 1)
            migrated_count += 1
            logger.warn "Migrated message #{migrated_count} from old queue to central queue"
          else
            logger.error "Failed to migrate message to central queue (queue full), dropping message"
            break
          end
        end

        if migrated_count >= max_migrations
          logger.error "Hit migration limit! Old queue still has #{existing_pending_queue.size} messages"
        end

        @subscriptions_mutex.synchronize { @subscriptions << sub }

        sub
      end

      def shutdown(timeout = 5)
        handlers = @pending_queue_handlers.select(&:alive?)
        return if handlers.empty?

        # Wake every handler with its own poison pill.
        handlers.size.times do
          # Clear some space if the queue is full so the shutdown signal fits.
          if @pending_queue.num_waiting.zero? && @pending_queue.size >= @pending_queue.max
            logger.warn "Queue full during shutdown, clearing to make room for shutdown signal"
            @pending_queue.clear rescue nil
          end

          # Push with a deadline (see push_with_deadline: no Timeout.timeout,
          # which corrupts the SizedQueue mutex on JRuby).
          unless push_with_deadline(:shutdown, 1)
            logger.error "Failed to send shutdown signal (queue blocked); will force-kill remaining handlers"
            break
          end
        end

        # Join all handlers within a single shared deadline, then force-kill stragglers.
        deadline = monotonic + timeout
        handlers.each do |handler|
          remaining = deadline - monotonic
          handler.join(remaining.positive? ? remaining : 0)
        end

        handlers.each do |handler|
          next unless handler.alive?
          logger.warn "Handler thread did not shut down in time, forcefully killing..."
          handler.kill
          handler.join(1) rescue nil
        end

        # Clean up queue
        @pending_queue.clear rescue nil
      end

      # Depth of the shared intake queue = intake backpressure (for observability).
      def pending_queue_size
        @pending_queue.size
      end

      # Resident bytes in the shared intake queue = heap backpressure (gauge).
      def pending_queue_bytes
        @pending_queue.bytesize
      end

      def unsubscribe_all
        # Take ownership and clear: pause/resume cycles re-subscribe from
        # scratch, so keeping the old entries only grew the array without bound
        # and re-unsubscribed dead subscriptions on every later pause.
        subscriptions = @subscriptions_mutex.synchronize do
          subs = @subscriptions.dup
          @subscriptions.clear
          subs
        end
        subscriptions.each do |sub|
          begin
            sub.unsubscribe
          rescue => e
            logger.warn "Failed to unsubscribe #{sub.subject rescue 'unknown'}: #{e.message}"
          end
        end
      end

      private

      def monotonic
        ::Protobuf::Nats.monotonic_time
      end

      # Push onto the shared SizedQueue with a deadline, WITHOUT Timeout.timeout.
      # Timeout uses an asynchronous Thread#raise, which is unsafe around the
      # mutex SizedQueue#push takes internally: on JRuby (10.x in particular) a
      # timeout firing mid-push unwinds through the held mutex and raises
      # "ThreadError: Attempt to unlock a mutex which is locked by another
      # thread/fiber" instead of Timeout::Error -- so the rescue :Timeout::Error
      # never fires and shutdown/migration blow up. CRuby happens to unwind
      # cleanly, which is why this only bit JRuby. Poll a non-blocking push
      # against a monotonic deadline instead: no async raise, safe on every
      # engine. Returns true if pushed, false if the deadline passed (queue
      # still full) or the queue was closed.
      def push_with_deadline(obj, timeout)
        deadline = monotonic + timeout
        loop do
          begin
            @pending_queue.push(obj, true) # non_block: raises ThreadError when full
            return true
          rescue ::ClosedQueueError
            return false
          rescue ::ThreadError
            return false if monotonic >= deadline
            sleep 0.01
          end
        end
      end

      # Spawn one intake handler. Each thread owns its own crash_count so the
      # self-healing exponential backoff is correct under true parallelism (a
      # shared counter would lose updates across handlers on JRuby). The counter
      # decays to zero once a handler processes a message again, so a later
      # transient crash restarts the backoff from 1s.
      def spawn_handler(index)
        ::Thread.new do
          ::Thread.current.name = "subscription-manager-#{object_id}-#{index}"
          crash_count = 0

          begin
            loop do
              msg = nil
              begin
                # --- Per-message processing ---
                msg = @pending_queue.pop

                # nil means the queue was closed (e.g. nats-pure closed the
                # swapped sub queue on connection close). A closed queue pops
                # nil immediately forever, so park briefly instead of raising
                # NoMethodError-per-iteration through the rescue below.
                if msg.nil?
                  sleep ::Protobuf::Nats::CLOSED_QUEUE_PARK_SECONDS
                  next
                end

                # Check for shutdown poison pill
                break if msg == :shutdown

                @callback.call(msg.data, msg.reply, msg.subject)
                crash_count = 0 unless crash_count.zero? # healthy: decay backoff
                # --- End per-message processing ---
              rescue => per_message_error
                # Log the error for the specific message, but DON'T kill the thread.
                logger.error("SubscriptionManager failed to process message: #{msg.inspect rescue 'unknown'}. Error: #{per_message_error.message}")
                ::Protobuf::Nats.notify_error_callbacks(per_message_error) rescue nil
              end
            end
          rescue => fatal_error
            raise if fatal_error.is_a?(SystemExit) || fatal_error.is_a?(Interrupt) || fatal_error.is_a?(SignalException)

            # This block is for fatal errors that crash the thread itself.
            logger.error("SubscriptionManager handler crashed fatally! Error: #{fatal_error.message}")
            ::Protobuf::Nats.notify_error_callbacks(fatal_error) rescue nil
            ::Protobuf::Nats.instrument("server.subscription_handler_crashed", 1) rescue nil

            # Self-healing with exponential backoff (per-thread counter).
            crash_count += 1
            sleep_duration = ::Protobuf::Nats.crash_backoff_seconds(crash_count)
            logger.warn("Waiting #{sleep_duration}s before restarting SubscriptionManager handler...")
            sleep sleep_duration

            retry  # Restart the loop
          end
        end
      end
    end
  end
end
