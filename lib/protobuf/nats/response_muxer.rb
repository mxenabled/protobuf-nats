require 'securerandom'
require "protobuf/nats"
require "protobuf/rpc/connectors/base"
require "monitor"
require "protobuf/nats/uuidv7_helper"
require "concurrent"
require "concurrent/collection/timeout_queue"

module Protobuf
  module Nats
    class ResponseMuxer
      LOCK = ::Mutex.new
      MAX_RESPONSES_PER_TOKEN = 10
      TOKEN_TTL_SECONDS = 600 # 10 minutes

      # The shared response subscription is bounded by BOTH a message count and a
      # byte ceiling; nats-pure drops (SlowConsumer) on whichever trips first, so
      # the firehose is capped at min(count, bytes) instead of buffering unbounded
      # protobuf payloads on the JVM heap (the 0.13.2 OOM). Dispatchers drain it to
      # ~0, so these are burst headroom, not a working set.
      #
      # The count is deliberately tighter than the ecosystem's per-subscription
      # defaults (nats-pure 65,536; nats.go 500,000): those bound off-heap buffers,
      # this is Ruby objects on the heap, and the byte cap is the real ceiling. The
      # byte default stays aligned at 64 MiB (nats-pure/nats.go both use it).
      # Override via PB_NATS_RESPONSE_MUXER_QUEUE_SIZE / _QUEUE_BYTES.
      DEFAULT_RESPONSE_QUEUE_SIZE = 1024
      DEFAULT_RESPONSE_QUEUE_BYTES = 64 * 1024 * 1024 # 64MiB

      # Sentinel pushed onto a token's queue to wake a waiter blocked in
      # next_message. We cannot rely on Queue#close alone: on JRuby, close does
      # NOT wake a pop() that is blocked with a timeout: -- neither the native
      # Queue (Ruby >= 3.2 / JRuby 10) nor concurrent-ruby's RubyTimeoutQueue
      # (Ruby < 3.2 / JRuby 9.4, whose timed pop only wakes on push) signals a
      # timed waiter on close. CRuby's Queue#close does wake it, which is why
      # this only ever bit JRuby. Pushing an explicit sentinel wakes the waiter
      # immediately on every engine; next_message treats it as a timeout.
      QUEUE_WAKE = ::Object.new

      # Thread-local key naming the subscription a dispatcher is currently
      # draining (see run_dispatch_loop / spawn_dispatcher).
      DISPATCHING_SUB_KEY = :pb_nats_dispatching_sub

      def initialize
        # Per-token response queues for lock-free message delivery. @resp_map is a
        # Concurrent::Map so request threads and dispatcher threads can insert,
        # look up, and delete tokens without serializing on a single mutex (on
        # JRuby it is backed by java.util.concurrent.ConcurrentHashMap). Each
        # value is a Hash { queue:, created_at: }.
        @resp_map = ::Concurrent::Map.new
        @resp_handlers = []
        @cleanup_thread = nil
        @shutdown = false
        @cleanup_mutex = ::Mutex.new
        @cleanup_cv = ::ConditionVariable.new
        @restarting = false  # Flag to prevent concurrent restarts
        # The connection object the inbox subscription lives on. Compared by
        # identity in #start so a rebuilt connection (nats-pure fired on_close
        # and start_client_nats_connection made a fresh client) triggers a
        # restart instead of leaving the muxer subscribed to a dead connection.
        # An AtomicReference (not a plain ivar) so #start's healthy fast path
        # can read it without taking LOCK -- start runs once per RPC, and on
        # JRuby a per-request LOCK acquisition is real contention. Writes still
        # happen only while holding LOCK.
        @subscribed_nats = ::Concurrent::AtomicReference.new(nil)

        # Shared self-healing backoff counter for the dispatcher pool. Atomic so
        # concurrent dispatchers don't lose updates when several crash at once,
        # and it decays back to zero once a dispatcher is healthy again (see
        # run_dispatch_loop), so a later transient crash restarts the backoff
        # from 1s instead of staying pinned at the cap.
        @crash_count = ::Concurrent::AtomicFixnum.new(0)

        # High-water mark of the response queue depth since the last cleanup
        # cycle. Sampled in the dispatch loop, emitted+reset by the cleanup thread
        # (response_muxer.pending_queue_peak) so a burst between gauge samples is
        # still visible.
        @pending_queue_peak = ::Concurrent::AtomicFixnum.new(0)
      end

      def logger
        ::Protobuf::Logging.logger
      end

      # Monotonic clock for token TTL accounting (single source of truth in
      # Protobuf::Nats.monotonic_time). Immune to wall-clock jumps.
      def monotonic_now
        ::Protobuf::Nats.monotonic_time
      end

      # Number of dispatcher threads draining the response subscription. On JRuby
      # (true parallelism) a single dispatcher is a hard throughput ceiling, so we
      # fan out to processor_count; on CRuby the GVL makes extra dispatchers
      # pointless, so we stay at 1. Overridable via env for tuning/tests.
      def dispatcher_count
        @dispatcher_count ||= begin
          default = ::RUBY_ENGINE == "jruby" ? ::Concurrent.processor_count : 1
          ::Protobuf::Nats.env_int("PB_NATS_RESPONSE_MUXER_DISPATCHERS", default, :min => 1)
        end
      end

      # Message-count and byte caps for the shared response subscription (see
      # DEFAULT_RESPONSE_QUEUE_SIZE / _BYTES). Read once each, in #start, so no
      # memoization is needed.
      def response_queue_size
        ::Protobuf::Nats.env_int("PB_NATS_RESPONSE_MUXER_QUEUE_SIZE", DEFAULT_RESPONSE_QUEUE_SIZE, :min => 1)
      end

      def response_queue_bytes
        ::Protobuf::Nats.env_int("PB_NATS_RESPONSE_MUXER_QUEUE_BYTES", DEFAULT_RESPONSE_QUEUE_BYTES, :min => 1)
      end

      # Current depth of the shared firehose; 0 before the muxer starts. Gauge for
      # observability -- mirrors SuperSubscriptionManager#pending_queue_size.
      def pending_queue_size
        @resp_sub&.pending_queue&.size || 0
      end

      def cleanup(token)
        # Atomic remove-and-return; wake+close the queue to release any waiter.
        entry = @resp_map.delete(token)
        wake_and_close_queue(entry[:queue]) if entry
      end

      # Wake any waiter blocked in next_message on this queue, then close it.
      # Pushing QUEUE_WAKE is what actually wakes a timed pop on JRuby (see the
      # QUEUE_WAKE comment); close alone is insufficient there. Safe to call on
      # an already-closed queue.
      def wake_and_close_queue(queue)
        return unless queue
        begin
          queue.push(QUEUE_WAKE)
        rescue ::ClosedQueueError, ::ThreadError
          # Already closed by another path; a plain (untimed) waiter, if any,
          # was already woken by that close. Nothing more to do.
        end
        queue.close
      end

      def next_message(token, timeout)
        # Lock-free get of the per-token queue.
        entry = @resp_map[token]
        queue = entry && entry[:queue]

        unless queue
          logger.warn "Token #{token} not found or already cleaned up during next_message"
          raise ::NATS::Timeout
        end

        # Handle edge case: zero or negative timeout
        if timeout && timeout <= 0
          raise ::NATS::Timeout
        end

        # Use TimeoutQueue's native timeout support for efficient, lock-free waiting per token
        # Each token has its own queue, eliminating contention between different requests
        begin
          # TimeoutQueue.pop(non_block, timeout: seconds)
          # - With timeout: blocks until message arrives or timeout expires (returns nil on timeout)
          # - Without timeout (nil): blocks indefinitely until message arrives
          msg = if timeout
                  queue.pop(false, timeout: timeout)
                else
                  queue.pop(false)
                end

          # Queue.pop returns nil when:
          # 1. The queue is closed
          # 2. The timeout expires
          # QUEUE_WAKE is the sentinel pushed by wake_and_close_queue to wake a
          # timed pop on JRuby (where close alone does not); treat it as a
          # timeout so the caller fails over instead of returning garbage.
          if msg.nil? || msg.equal?(QUEUE_WAKE)
            logger.warn "Queue closed or timeout for token #{token} during next_message"
            raise ::NATS::Timeout
          end

          msg
        rescue ThreadError
          # Queue was closed - treat as timeout
          logger.warn "Queue closed for token #{token} during next_message"
          raise ::NATS::Timeout
        end
      end

      def new_request
        # Use UUIDv7 so we can figure out what time a message was originally created in-memory.
        token = UUIDv7Helper.generate # nats.new_inbox with nuid is not threadsafe.

        # Create a dedicated queue for this token. Concurrent::Map#[]= is atomic,
        # so no surrounding lock is required.
        @resp_map[token] = {
          queue: ::Concurrent::Collection::TimeoutQueue.new,
          created_at: monotonic_now
        }

        ResponseMuxerRequest.new(self, token)
      end

      def publish(subject, data, token)
        # Validate muxer started before publish
        unless @resp_inbox_prefix
          raise ::Protobuf::Nats::Errors::ResponseMuxer, "ResponseMuxer not started - cannot publish"
        end

        nats = Protobuf::Nats.client_nats_connection
        # The memoized connection is dropped when nats-pure fires on_close
        # (reconnect attempts exhausted). Raise the muxer's retryable error
        # instead of NoMethodError-on-nil so the client's transient-transport
        # retry path rebuilds the connection and tries again.
        if nats.nil?
          raise ::Protobuf::Nats::Errors::ResponseMuxer, "NATS connection unavailable (closed and not yet rebuilt) - cannot publish"
        end

        reply_to = "#{@resp_inbox_prefix}.#{token}"
        nats.publish(subject, data, reply_to)
      end

      def restart
        logger.debug "restarting response_muxer"

        # Prevent concurrent restarts - only one restart at a time
        LOCK.synchronize do
          if @restarting
            logger.warn "Restart already in progress, skipping concurrent restart request"
            return
          end
          @restarting = true
        end

        # Yield so other restart callers spawned around the same time get a
        # chance to reach the @restarting check above and skip. Without this,
        # CRuby's GVL can let the current thread run the entire restart to
        # completion (clearing @restarting) before sibling threads even enter
        # the method, defeating the concurrent-restart guard.
        Thread.pass

        begin
          # Stop the existing muxer first, if it's running
          LOCK.synchronize do
            @resp_handlers.each(&:kill)
            @resp_handlers.clear
            drop_subscription_locked("during restart")

            # Stop the cleanup thread
            stop_cleanup_thread
          end

          # Then start it fresh.
          start
        ensure
          # Always clear the restarting flag
          LOCK.synchronize { @restarting = false }
        end
      end

      def start
        current_nats = ::Protobuf::Nats.client_nats_connection

        # Runs in Client#initialize, i.e. once per RPC, so the healthy path is
        # lock-free: a volatile read of the connection the inbox subscription
        # lives on. When set, also detect a replaced connection (nats-pure
        # fired on_close, on_close dropped the memoized client, and the next
        # request built a fresh one): our inbox subscription lived on the dead
        # connection, so without a rebuild every response would be lost and
        # every RPC would time out until the process restarted.
        subscribed = @subscribed_nats.get
        return if subscribed && (current_nats.nil? || subscribed.equal?(current_nats))

        # Slow path: not started, or the connection was replaced. Re-check
        # under LOCK (double-checked locking; the atomic read above may race a
        # concurrent start/restart).
        stale = false
        LOCK.synchronize do
          if _started?
            return if current_nats.nil? || @subscribed_nats.get.equal?(current_nats)
            stale = true
          end
        end

        if stale
          logger.warn "ResponseMuxer NATS connection was replaced; restarting the muxer on the new connection"
          restart
          return
        end

        LOCK.synchronize do
          # We check this twice in case another thread was waiting for the lock to
          # start this party. Use the unlocked check to prevent deadlocks.
          return if _started?

          nats = ::Protobuf::Nats.client_nats_connection
          return if nats.nil?

          # Clean up partial state on exception
          begin
            @resp_inbox_prefix = nats.new_inbox

            # Subscribe to our per-instance inbox.
            @resp_sub = nats.subscribe("#{@resp_inbox_prefix}.*")

            # The dispatch loop takes @resp_sub.synchronize to decrement
            # pending_size after each pop, which keeps the finite byte cap accurate.
            # nats-pure's Subscription includes MonitorMixin, so this always holds;
            # if it ever doesn't, nats-pure's internals changed in a way that would
            # break byte accounting (a growing counter that false-trips the limit
            # and drops every response). Fail loudly rather than degrade silently.
            unless @resp_sub.respond_to?(:synchronize)
              raise ::Protobuf::Nats::Errors::IncompatibleSubscription,
                "NATS subscription does not respond to #synchronize; cannot maintain pending_size byte accounting (nats-pure internals changed?)"
            end

            # Bound the firehose by both message count and bytes (see
            # DEFAULT_RESPONSE_QUEUE_SIZE / _BYTES).
            @resp_sub.pending_msgs_limit = response_queue_size
            @resp_sub.pending_bytes_limit = response_queue_bytes
            @subscribed_nats.set(nats)
            @started = true
          rescue => e
            # Clean up partial state
            @resp_inbox_prefix = nil
            @resp_sub = nil
            @subscribed_nats.set(nil)
            @started = false
            logger.error "Failed to start ResponseMuxer: #{e.message}"
            raise
          end
        end

        # Start the cleanup thread
        start_cleanup_thread

        # Top up the dispatcher pool to dispatcher_count. Prunes dead threads
        # first so self-healing restarts converge to the target count instead of
        # multiplying threads.
        LOCK.synchronize do
          @resp_handlers.select!(&:alive?)
          @resp_handlers << spawn_dispatcher while @resp_handlers.size < dispatcher_count
        end
      end

      def started?
        LOCK.synchronize { _started? }
      end

      # True when the muxer's inbox subscription lives on this exact connection
      # object. Identity (not equality) is the point: a rebuilt connection to
      # the same servers is still a different socket with no subscriptions.
      def subscribed_to?(nats)
        @subscribed_nats.get.equal?(nats)
      end

      # Token TTL. Floors at TOKEN_TTL_SECONDS but stretches when the client's
      # response_timeout is configured beyond it -- otherwise the cleanup thread
      # would close a token's queue out from under a caller still legitimately
      # waiting on a long response.
      def token_ttl_seconds
        @token_ttl_seconds ||= [TOKEN_TTL_SECONDS, ::Protobuf::Nats.client_response_timeout + 60].max
      end

      # Periodic cleanup of stale tokens
      def cleanup_stale_tokens
        cutoff = monotonic_now - token_ttl_seconds

        # Collect stale tokens first, then delete. Concurrent::Map iteration does
        # not hold a global lock, so request threads are never blocked across this
        # O(n) scan (unlike the previous single-mutex implementation).
        stale_tokens = []
        @resp_map.each_pair do |token, data|
          created_at = data[:created_at]
          stale_tokens << token if created_at && created_at < cutoff
        end

        stale_count = 0
        stale_tokens.each do |token|
          data = @resp_map.delete(token)
          next unless data
          stale_count += 1
          logger.warn "Cleaning up stale token #{token} created at #{data[:created_at]}"
          # Wake any waiting thread, then close the queue.
          wake_and_close_queue(data[:queue])
        end

        if stale_count > 0
          ::Protobuf::Nats.instrument "response_muxer.stale_tokens_cleaned", stale_count
        end

        # Gauge the shared response firehose so a climbing backlog is visible
        # before it turns into timeouts/SlowConsumer drops. current == depth at
        # sample time; peak == high-water since the last cycle (reset here).
        ::Protobuf::Nats.instrument "response_muxer.pending_queue_size", pending_queue_size
        # Atomic read-and-reset of the high-water mark (AtomicFixnum has no
        # get_and_set): capture the prior value inside the update block.
        peak = 0
        @pending_queue_peak.update do |current_value|
          peak = current_value
          0 # set to 0
        end
        ::Protobuf::Nats.instrument "response_muxer.pending_queue_peak", peak
      end

      # Stop the cleanup thread
      def stop
        LOCK.synchronize do
          stop_cleanup_thread
          @resp_handlers.each(&:kill)
          @resp_handlers.clear
          drop_subscription_locked("during stop")
        end
      end

      private

      def _started?
        !!@started
      end

      # Tear down the inbox subscription and mark the muxer stopped. Must be
      # called while holding LOCK; `context` labels the failure log.
      def drop_subscription_locked(context)
        if @resp_sub
          begin
            @resp_sub.unsubscribe
          rescue => e
            logger.warn "Failed to unsubscribe old response muxer subscription #{context}: #{e.message}"
          ensure
            # Always set to nil, even if unsubscribe raises
            @resp_sub = nil
          end
        end
        @subscribed_nats.set(nil)
        @started = false

        # The inbox prefix dies with the subscription (start generates a fresh
        # one), so no in-flight response can ever arrive -- without this, each
        # waiter sits blocked until its ack/response timeout expires. Closing a
        # token's queue wakes its waiter immediately (next_message raises
        # NATS::Timeout), which rides the client's existing retry path onto the
        # new connection. Entries stay in @resp_map: the owning request's
        # ensure-cleanup (or the TTL sweep) removes them, and dispatchers
        # already drop pushes to a closed queue.
        fail_inflight_requests
      end

      # Must be called while holding LOCK (only from drop_subscription_locked).
      def fail_inflight_requests
        @resp_map.each_pair do |_token, entry|
          wake_and_close_queue(entry[:queue])
        end
      end

      # Spawn a single dispatcher thread. Multiple dispatchers safely share the
      # one @resp_sub.pending_queue (Queue is thread-safe) and route via the
      # lock-free @resp_map.
      def spawn_dispatcher
        Thread.new do
          # Unique thread name for debugging
          Thread.current.name = "response-muxer-#{Thread.current.object_id}"
          begin
            run_dispatch_loop
          rescue => fatal_error
            # Only truly fatal errors that kill the loop reach here (ThreadError
            # from the shared pending_queue being closed).
            logger.error("ResponseMuxer thread crashed fatally. Error: #{fatal_error.message}")
            ::Protobuf::Nats.notify_error_callbacks(fatal_error)

            # --- Self-healing logic ---
            # Atomic increment so simultaneous crashes don't lose updates. The
            # counter decays in run_dispatch_loop once a dispatcher is healthy,
            # so this only grows under a sustained crash loop.
            crashes = @crash_count.increment
            # Exponential backoff, e.g., 1, 4, 9, 16s... capped at 60s (shared formula).
            sleep_duration = ::Protobuf::Nats.crash_backoff_seconds(crashes)
            logger.warn("Waiting #{sleep_duration}s before attempting to restart ResponseMuxer.")
            sleep sleep_duration
            # --- End of self-healing logic ---

            # After sleeping, reset the state and try to start again.
            LOCK.synchronize do
              # Remove ourselves from the handler pool BEFORE start re-tops it up.
              # This thread is still alive (running this rescue) but is about to
              # exit, so start's `select!(&:alive?)` would otherwise count it as a
              # live dispatcher and spawn no replacement -- leaving the pool one
              # short (zero dispatchers on CRuby, where dispatcher_count == 1, and
              # the muxer would stop delivering responses entirely).
              @resp_handlers.delete(::Thread.current)

              # Only tear down the subscription we actually died on. When several
              # dispatchers crash together they wake on different backoffs (1s,
              # then 4s...), so an unconditional teardown here would destroy the
              # subscription an earlier sibling just rebuilt and, via
              # fail_inflight_requests, cancel every request that had already
              # arrived on it. If a sibling healed us, our subscription is stale
              # and start's top-up below is all that is left to do.
              #
              # DISPATCHING_SUB_KEY is written by run_dispatch_loop on this same
              # thread, so it names the subscription this dispatcher was really
              # draining. Capturing @resp_sub here (or when the thread starts)
              # would instead read whatever is current after the backoff, which
              # is exactly the value we need to compare against. A nil value
              # means we died before draining anything, so there is nothing of
              # ours to tear down.
              dispatching_sub = ::Thread.current[DISPATCHING_SUB_KEY]
              if @resp_sub.nil? || @resp_sub.equal?(dispatching_sub)
                drop_subscription_locked("during self-healing")
              else
                logger.info "ResponseMuxer already healed by another dispatcher; rejoining the pool without a teardown"
              end
            end
            start
          end
        end
      end

      def run_dispatch_loop
        loop do
          begin
            # --- Start of per-message block ---
            # @resp_sub can briefly be nil during a restart. Park instead of
            # dereferencing nil, which would raise NoMethodError every iteration
            # and busy-spin (flooding logs and error callbacks) until it is set.
            sub = @resp_sub
            if sub.nil?
              sleep 0.01
              next
            end

            # Record what we are draining for the crash handler in
            # spawn_dispatcher. Thread-local, so each dispatcher tracks its own
            # subscription across restarts (a shared ivar could not).
            ::Thread.current[DISPATCHING_SUB_KEY] = sub

            msg = sub.pending_queue.pop

            # nil means the queue was closed/woken (e.g. the connection died
            # and its queue was closed). A closed queue returns nil immediately
            # forever, so park briefly instead of spinning at 100% CPU until a
            # restart swaps in a live subscription.
            if msg.nil?
              sleep ::Protobuf::Nats::CLOSED_QUEUE_PARK_SECONDS
              next
            end

            # Drop the popped message's bytes from pending_size. nats-pure only
            # decrements it in #process, which we bypass by popping pending_queue
            # directly; without this the counter climbs monotonically and would
            # false-trip the finite pending_bytes_limit, dropping every later
            # response. Take the same monitor nats-pure's read thread uses.
            # (#start guarantees the subscription responds to #synchronize.)
            sub.synchronize { sub.pending_size -= msg.data.size }

            # Sample post-pop depth into the high-water mark so a burst that fills
            # and drains between the 60s gauge samples is still visible.
            depth = sub.pending_queue.size
            @pending_queue_peak.update { |current_value| [depth, current_value].max }

            dispatch_message(msg)

            # A processed message means this dispatcher is healthy: let the
            # self-healing backoff decay so a later transient crash restarts the
            # backoff from 1s. Only write when non-zero to keep this cheap.
            @crash_count.value = 0 unless @crash_count.value.zero?
            # --- End of per-message block ---
          rescue => per_message_error
            # ThreadError is fatal, it means the queue is closed and the loop cannot continue.
            raise if per_message_error.is_a?(::ThreadError)

            # Log the error for the specific message, but DON'T kill the thread.
            logger.error("ResponseMuxer failed to process a message. Error: #{per_message_error.message}")
            ::Protobuf::Nats.notify_error_callbacks(per_message_error)
          end
        end
      end

      def dispatch_message(msg)
        # Validate message subject before processing
        unless msg.subject.is_a?(String) && msg.subject.include?('.')
          ::Protobuf::Nats.instrument "client.invalid_message", 1

          logger.warn "Received message with invalid subject: #{msg.subject}. Dropping."
          return
        end

        # example(random data):
        # _INBOX.{random_data}.{random_data_msg_id}
        # Hot path: take the last segment via rindex/slice instead of split,
        # which allocates an array plus a string per segment for every response.
        # The include?('.') check above guarantees rindex is non-nil.
        subject = msg.subject
        token = subject[(subject.rindex(".") + 1)..]

        logger.debug { "token: #{token}, resp_map.keys:#{@resp_map.keys}" } if logger.debug?

        # Lock-free get of the per-token queue.
        entry = @resp_map[token]
        queue = entry && entry[:queue]

        unless queue
          # Try to decode the UUIDv7 timestamp to calculate message age
          delay_seconds = UUIDv7Helper.age_in_seconds(token)

          ::Protobuf::Nats.instrument "client.unexpected_message", delay_seconds || 1

          if delay_seconds
            logger.warn "Received unexpected message (#{delay_seconds.round(3)}s old). MSG.subject=#{msg.subject}. RESP_SUBJ.subject=#{@resp_sub.subject rescue 'unknown'}. Dropping unexpected message."
          else
            logger.warn "Received unexpected message. MSG.subject=#{msg.subject}. RESP_SUBJ.subject=#{@resp_sub.subject rescue 'unknown'}. Dropping unexpected message."
          end
          return
        end

        # Push message onto the queue - this is lock-free and thread-safe.
        begin
          # Check queue size to prevent memory bloat
          if queue.size >= MAX_RESPONSES_PER_TOKEN
            logger.warn "Token #{token} has #{queue.size} queued responses. Possible duplicate messages or slow consumer. Dropping message."
            return
          end

          queue.push(msg)
        rescue ThreadError
          # Queue was closed (cleanup happened) - this is fine, just drop the message
          logger.debug "Queue closed for token #{token}, dropping message"
        end
      end

      def start_cleanup_thread
        # Only start if not already running
        return if @cleanup_thread&.alive?

        @cleanup_mutex.synchronize { @shutdown = false }
        @cleanup_thread = Thread.new do
          begin
            loop do
              # Wait for 60 seconds or until signaled to shutdown
              @cleanup_mutex.synchronize do
                @cleanup_cv.wait(@cleanup_mutex, 60) unless @shutdown
              end

              break if @cleanup_mutex.synchronize { @shutdown }

              begin
                cleanup_stale_tokens
              rescue => error
                logger.error("ResponseMuxer cleanup thread error: #{error.message}")
                ::Protobuf::Nats.notify_error_callbacks(error)
              end
            end
          rescue => fatal_error
            logger.error("ResponseMuxer cleanup thread crashed: #{fatal_error.message}")
            ::Protobuf::Nats.notify_error_callbacks(fatal_error)
          end
        end
        # Name the thread from the outside so the name is visible to callers
        # immediately after start_cleanup_thread returns (no race with the
        # thread body executing).
        @cleanup_thread.name = "response-muxer-cleanup-#{object_id}"
      end

      def stop_cleanup_thread
        if @cleanup_thread&.alive?
          @cleanup_mutex.synchronize do
            @shutdown = true
            @cleanup_cv.signal # Wake up the cleanup thread immediately
          end
          # Should exit almost immediately now
          @cleanup_thread.join(0.5)
          # Force kill if still alive (shouldn't happen)
          @cleanup_thread.kill if @cleanup_thread&.alive?
        end
        @cleanup_thread = nil
      end
    end
  end
end
