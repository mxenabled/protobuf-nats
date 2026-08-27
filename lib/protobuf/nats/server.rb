require "active_support"
require "active_support/core_ext/class/subclasses"
require "concurrent"
require "protobuf/rpc/server"
require "protobuf/rpc/service"
require "protobuf/nats/thread_pool"
require "protobuf/nats/uuidv7_helper"

module Protobuf
  module Nats
    class Server
      include ::Protobuf::Rpc::Server
      include ::Protobuf::Logging

      attr_reader :nats, :thread_pool, :subscription_manager

      MILLISECOND = 1000

      def initialize(options)
        @options = options
        @processing_requests = true
        @running = true
        @stopped = false
        @pause_mutex = ::Mutex.new

        @nats = @options[:client] || ::Protobuf::Nats::NatsClient.new

        # Register lifecycle callbacks BEFORE connecting so a disconnect or
        # error during the initial handshake is still observed (mirrors
        # Protobuf::Nats.start_client_nats_connection on the client side).
        @nats.on_disconnect do
          logger.warn "Server NATS connection was disconnected"
        end

        @nats.on_reconnect do
          logger.warn "Server NATS connection was reconnected"
        end

        @nats.on_error do |error|
          # Runs on nats-pure's read/flush thread -- offload so a slow callback
          # can't stall the server's intake.
          ::Protobuf::Nats.notify_error_callbacks_async(error)
        end

        @nats.on_close do
          handle_connection_closed
        end

        @nats.connect(::Protobuf::Nats.config.connection_options)

        @thread_pool = ::Protobuf::Nats::ThreadPool.new(threads, :max_queue => max_queue_size)

        @subscription_manager = ::Protobuf::Nats::SuperSubscriptionManager.new(@nats) do |request_data, reply_id, subject|
          # Opt-in intake shedding; rationale on #stale_request_ms.
          next if stale_request?(reply_id)

          unless enqueue_request(request_data, reply_id)
            logger.error { "Thread pool is full! Dropping message for subject: #{subject}" }
          end
        end
        @server = options.fetch(:server, ::Socket.gethostname)

        # In-flight handler tracking for observability. Long-running handlers are
        # allowed (and never aborted); we only measure/report. id => monotonic
        # start time; @overdue_flagged dedupes the per-handler overdue event.
        @inflight = ::Concurrent::Map.new
        @overdue_flagged = ::Concurrent::Map.new
        @request_seq = ::Concurrent::AtomicFixnum.new(0)
      end

      def monotonic
        ::Protobuf::Nats.monotonic_time
      end

      def handler_count
        subscription_manager.handler_count
      end

      # Informational SLA marker for slow handlers. Default 0 (off) so normal
      # long-running operations are not flagged.
      def slow_handler_threshold_ms
        @slow_handler_threshold_ms ||= ::Protobuf::Nats.env_int("PB_NATS_SERVER_SLOW_HANDLER_THRESHOLD_MS", 0)
      end

      # Age (ms) beyond which a request is shed at intake instead of processed:
      # a request whose client has already retried or timed out is abandoned
      # work -- executing it only burns a pool slot (and duplicates effects for
      # non-idempotent RPCs). Default 0 (off). The age comes from the UUIDv7
      # token this gem's client embeds in the reply inbox, which encodes
      # *client wall-clock* time -- enable only with sane NTP across hosts, and
      # keep the threshold comfortably above the client's ack_timeout (5s
      # default) to absorb skew.
      def stale_request_ms
        @stale_request_ms ||= ::Protobuf::Nats.env_int("PB_NATS_SERVER_STALE_REQUEST_MS", 0)
      end

      def stale_request?(reply_id)
        return false unless stale_request_ms.positive?

        age_ms = ::Protobuf::Nats::UUIDv7Helper.age_ms(reply_id.to_s[/[^.]*\z/])
        return false if age_ms.nil? || age_ms < stale_request_ms

        logger.debug { "Dropping stale request (age=#{age_ms}ms >= #{stale_request_ms}ms); the client has already retried or timed out" }
        ::Protobuf::Nats.instrument "server.stale_request_dropped", age_ms
        true
      end

      # A handler still running past this is "overdue": the client has already
      # given up (its response_timeout), so the work is orphaned and holding a
      # pool slot for nothing. Defaults above the client's 60s response_timeout
      # so legitimate ≤60s operations are never flagged.
      def handler_overdue_ms
        @handler_overdue_ms ||= ::Protobuf::Nats.env_int("PB_NATS_SERVER_HANDLER_OVERDUE_MS", 65_000)
      end

      # Whether to actively reclaim (abort) an overdue handler's pool slot. OFF by
      # default: the documented contract is that handlers are never aborted, since
      # killing a thread mid-handler can corrupt state. Enable only when you would
      # rather shed orphaned work (whose client already gave up) than let it pin a
      # pool slot -- e.g. when overdue handlers are saturating the pool and the
      # server is NACKing healthy traffic. Reclaim raises Errors::HandlerOverdue
      # into the worker, which the handler rescue turns into an RPC error response.
      def reclaim_overdue_handlers?
        # Memoize the raw string (never falsey, so ||= is safe) and derive the
        # boolean per call -- avoids the nil-guard dance for a false-able memo.
        @reclaim_overdue_handlers ||= ::ENV.fetch("PB_NATS_SERVER_RECLAIM_OVERDUE_HANDLERS", "false")
        @reclaim_overdue_handlers == "true"
      end

      # How long to let in-flight handlers finish on shutdown. Tracks the overdue
      # window (plus grace) so a legitimate long handler isn't killed mid-flight.
      def shutdown_drain_timeout
        @shutdown_drain_timeout ||= ::Protobuf::Nats.env_float("PB_NATS_SERVER_SHUTDOWN_DRAIN_TIMEOUT", (handler_overdue_ms / 1000.0) + 5)
      end

      def instrument_thread_pool_sizes
        ::Protobuf::Nats.instrument("server.thread_pool_enqueued_size", thread_pool.enqueued_size)
        ::Protobuf::Nats.instrument("server.thread_pool_max_size", thread_pool.max_size)
        ::Protobuf::Nats.instrument("server.thread_pool_running_size", thread_pool.size)
      end

      # Periodic in-flight handler health. Long handlers are normal, so
      # inflight_oldest_age_ms can legitimately approach the client's
      # response_timeout; only overdue_handler_count (work the client has already
      # abandoned) signals a problem.
      def instrument_inflight_handlers
        now = monotonic
        overdue_ms = handler_overdue_ms
        count = 0
        oldest_age_ms = 0.0
        overdue = 0

        @inflight.each_pair do |id, entry|
          started_at, handler_thread = entry
          count += 1
          age_ms = (now - started_at) * MILLISECOND
          oldest_age_ms = age_ms if age_ms > oldest_age_ms
          next unless overdue_ms.positive? && age_ms >= overdue_ms

          overdue += 1

          # Optionally reclaim the slot by aborting the orphaned handler (opt-in;
          # see #reclaim_overdue_handlers?). Done before the dedupe below so the
          # reclaim is attempted even after the overdue event was already emitted.
          # The @inflight re-check narrows the window in which the raise could
          # land on a worker that already finished this request and moved on to
          # another (the ThreadPool worker also swallows a raise that lands
          # between tasks).
          if reclaim_overdue_handlers? && handler_thread&.alive? && @inflight[id].equal?(entry)
            logger.warn "Reclaiming overdue handler (age=#{age_ms.round}ms, client already gave up) to free its pool slot"
            handler_thread.raise(::Protobuf::Nats::Errors::HandlerOverdue, "handler exceeded #{overdue_ms}ms; reclaimed")
            ::Protobuf::Nats.instrument("server.handler_reclaimed", age_ms)
          end

          # Emit the per-handler overdue event once (the client has already
          # given up; this handler's result is orphaned).
          next if @overdue_flagged[id]
          @overdue_flagged[id] = true
          logger.warn "Handler exceeded #{overdue_ms}ms (client already gave up); in-flight age=#{age_ms.round}ms"
          ::Protobuf::Nats.instrument("server.handler_overdue", age_ms)
        end

        ::Protobuf::Nats.instrument("server.pending_intake_queue_size", subscription_manager.pending_queue_size)
        ::Protobuf::Nats.instrument("server.pending_intake_queue_bytes", subscription_manager.pending_queue_bytes)
        ::Protobuf::Nats.instrument("server.inflight_count", count)
        ::Protobuf::Nats.instrument("server.inflight_oldest_age_ms", oldest_age_ms)
        ::Protobuf::Nats.instrument("server.overdue_handler_count", overdue)

        # Reap orphaned overdue flags. The handler's ensure normally deletes
        # @overdue_flagged[id], but the flag set above can race a completing
        # handler: we read id from @inflight, the ensure deletes both maps, then
        # we set @overdue_flagged[id] -- an entry nothing else will ever remove.
        # A flag whose id is no longer in-flight is by definition orphaned.
        @overdue_flagged.each_key do |id|
          @overdue_flagged.delete(id) unless @inflight.key?(id)
        end
      end

      # Defaults to #threads (not the raw option) so a server built with no
      # :threads option gets a queue matching its 10 default workers instead of
      # nil.to_i == 0.
      def max_queue_size
        ::Protobuf::Nats.env_int("PB_NATS_SERVER_MAX_QUEUE_SIZE", threads)
      end

      def slow_start_delay
        @slow_start_delay ||= ::Protobuf::Nats.env_int("PB_NATS_SERVER_SLOW_START_DELAY", 10)
      end

      def subscriptions_per_rpc_endpoint
        @subscriptions_per_rpc_endpoint ||= ::Protobuf::Nats.env_int("PB_NATS_SERVER_SUBSCRIPTIONS_PER_RPC_ENDPOINT", 10)
      end

      def threads
        @options[:threads] || 10 # Default to 10 if not provided, consistent with original behavior
      end

      def service_klasses
        ::Protobuf::Rpc::Service.implemented_services.map(&:safe_constantize)
      end

      def enqueue_request(request_data, reply_id)
        ::Protobuf::Nats.instrument "server.message_received"

        enqueued_at = monotonic
        request_id = @request_seq.increment
        was_enqueued = thread_pool.push do
          # nil response_data is the "handler failed, don't publish a success
          # response" sentinel (a successful encode is always a non-nil String,
          # even when empty).
          response_data = nil
          begin
            # Instrument the thread pool time-to-execute duration.
            processed_at = monotonic
            ::Protobuf::Nats.instrument("server.thread_pool_execution_delay", (processed_at - enqueued_at) * MILLISECOND)

            # Track this handler as in-flight (long handlers are allowed; this is
            # only for observability -- we never abort it unless overdue-reclaim
            # is explicitly enabled). Store the worker thread so reclaim can
            # target it; the start time drives age/overdue accounting.
            @inflight[request_id] = [processed_at, ::Thread.current]

            # Process request. Only the handler is wrapped here so a transport
            # failure on the success-response publish (below) cannot fall into
            # this rescue and emit a *second* (error) publish for a request whose
            # handler actually succeeded.
            begin
              response_data = handle_request(request_data, 'server' => @server)
            rescue => error
              response_data = nil # ensure the success-publish below is skipped
              logger.debug { "rescued error => #{error}" }  if logger.debug?
              # Logs the real error server-side (via the default log_error
              # callback) so it isn't lost; the client gets only a generic message.
              ::Protobuf::Nats.notify_error_callbacks(error)

              # The client has already received our ACK and is now blocked waiting
              # for the response message. If we don't send one it will hang until
              # response_timeout (60s by default). Publish an encoded RPC error so
              # the client fails fast instead. Use a generic message rather than
              # error.message so internal handler details aren't leaked over the
              # wire. (If the failure was the connection itself, this publish will
              # also fail and is swallowed below.)
              begin
                error_response = ::Protobuf::Rpc::PbError.new("Internal server error")
                nats.publish(reply_id, error_response.encode)
              rescue => publish_error
                logger.error "Failed to publish error response for #{reply_id}: #{publish_error.message}"
              end
            end

            # Publish the successful response. Kept outside the handler rescue so a
            # publish failure here is logged rather than triggering a duplicate
            # (error) response for a request that already succeeded.
            if response_data
              logger.debug { "Publishing response to #{reply_id}" } if logger.debug?
              begin
                nats.publish(reply_id, response_data)
              rescue => publish_error
                logger.error "Failed to publish response for #{reply_id}: #{publish_error.message}"
                ::Protobuf::Nats.notify_error_callbacks(publish_error)
              end
            end
          ensure
            @inflight.delete(request_id)
            @overdue_flagged.delete(request_id)

            # Instrument the request duration.
            completed_at = monotonic
            ::Protobuf::Nats.instrument("server.request_duration", (completed_at - enqueued_at) * MILLISECOND)

            # Informational slow-handler marker (opt-in; default off).
            if processed_at && slow_handler_threshold_ms.positive?
              handler_ms = (completed_at - processed_at) * MILLISECOND
              if handler_ms >= slow_handler_threshold_ms
                logger.warn "Slow handler for #{reply_id}: #{handler_ms.round}ms"
                ::Protobuf::Nats.instrument("server.slow_handler", handler_ms)
              end
            end
          end
        end

        # Publish an ACK to signal the server has picked up the work.
        begin
          if was_enqueued
            logger.debug { "[reply_id=#{reply_id}] Sending ACK" } if logger.debug?
            nats.publish(reply_id, ::Protobuf::Nats::Messages::ACK)
          else # Drop message if the thread pool is full
            ::Protobuf::Nats.instrument "server.thread_pool_saturated"
            ::Protobuf::Nats.instrument "server.message_dropped"
            logger.debug { "[reply_id=#{reply_id}] Sending NACK" } if logger.debug?

            # Let the client know we are not processing the message.
            nats.publish(reply_id, ::Protobuf::Nats::Messages::NACK)
          end
        rescue => e
          logger.error "Failed to send ACK/NACK for #{reply_id}: #{e.message}"
          ::Protobuf::Nats.notify_error_callbacks(e)
        end

        was_enqueued
      end

      def do_not_subscribe_to_includes?(subscription_key)
        return false unless ::Protobuf::Nats.config.server_subscription_key_do_not_subscribe_to_when_includes_any_of.respond_to?(:any?)
        return false if ::Protobuf::Nats.config.server_subscription_key_do_not_subscribe_to_when_includes_any_of.empty?

        ::Protobuf::Nats.config.server_subscription_key_do_not_subscribe_to_when_includes_any_of.any? do |key|
          subscription_key.include?(key)
        end
      end

      def only_subscribe_to_includes?(subscription_key)
        return true unless ::Protobuf::Nats.config.server_subscription_key_only_subscribe_to_when_includes_any_of.respond_to?(:any?)
        return true if ::Protobuf::Nats.config.server_subscription_key_only_subscribe_to_when_includes_any_of.empty?

        ::Protobuf::Nats.config.server_subscription_key_only_subscribe_to_when_includes_any_of.any? do |key|
          subscription_key.include?(key)
        end
      end

      def pause_file_path
        ::ENV.fetch("PB_NATS_SERVER_PAUSE_FILE_PATH", nil)
      end

      def print_subscription_keys
        logger.info "Creating subscriptions:"

        with_each_subscription_key do |subscription_key|
          logger.info "  - #{subscription_key}"
        end
      end

      def subscribe_to_services_once
        with_each_subscription_key do |subscription_key_and_queue|
          subscription_manager.queue_subscribe(subscription_key_and_queue)
        end
      end

      def with_each_subscription_key
        fail ::ArgumentError unless block_given?

        service_klasses.each do |service_klass|
          service_klass.rpcs.each do |service_method, _|
            # Skip services that are not implemented.
            next unless service_klass.method_defined?(service_method)
            subscription_key = ::Protobuf::Nats.subscription_key(service_klass, service_method)
            next if do_not_subscribe_to_includes?(subscription_key)
            next unless only_subscribe_to_includes?(subscription_key)

            yield subscription_key
          end
        end
      end

      # Slow start subscriptions by adding X rounds of subz every
      # Y seconds, where X is subscriptions_per_rpc_endpoint and Y is
      # slow_start_delay.
      def finish_slow_start
        logger.info "Slow start has started..."
        completed = 1

        # We have (X - 1) here because we always subscribe at least once.
        (subscriptions_per_rpc_endpoint - 1).times do
          unless @running
            logger.info "Slow start interrupted (server stopping) after #{completed}/#{subscriptions_per_rpc_endpoint} rounds"
            return
          end

          if paused?
            logger.info "Slow start interrupted (server paused) after #{completed}/#{subscriptions_per_rpc_endpoint} rounds"
            return
          end

          completed += 1
          sleep slow_start_delay
          subscribe_to_services_once
          logger.info "Slow start adding another round of subscriptions (#{completed}/#{subscriptions_per_rpc_endpoint})..."
        end

        logger.info "Slow start finished successfully (#{completed}/#{subscriptions_per_rpc_endpoint} rounds completed)."
      end

      def detect_and_handle_a_pause
        @pause_mutex.synchronize do
          case
          # If we are taking requests and detect a pause file, then unsubscribe.
          when @processing_requests && paused?
            @processing_requests = false
            logger.warn("Pausing server!")
            unsubscribe

          # If we were paused and the pause file is no longer present, then subscribe again.
          when !@processing_requests && !paused?
            logger.warn("Resuming server: resubscribing to all services and restarting slow start!")
            @processing_requests = true
            subscribe
          end
        end
      end

      def paused?
        !pause_file_path.nil? && ::File.exist?(pause_file_path)
      end

      # nats-pure fires on_close when the connection is terminally closed:
      # either we called close (normal shutdown, @running already false) or the
      # reconnect loop exhausted max_reconnect_attempts on every server in the
      # pool. In the latter case the server would otherwise keep running forever
      # with a dead connection -- subscribed to nothing, receiving nothing --
      # indistinguishable from healthy-but-idle. Stop the run loop instead so
      # the process exits and the supervisor (systemd/k8s/foreman) restarts it
      # with a fresh connection. Deployments that prefer in-process retries
      # forever can set max_reconnect_attempts: -1, in which case nats-pure
      # never fires this for a mere outage.
      def handle_connection_closed
        return unless @running
        logger.error "Server NATS connection was closed unexpectedly (reconnect attempts exhausted); stopping server so a supervisor can restart it"
        ::Protobuf::Nats.instrument "server.connection_closed"
        stop
      end

      def run
        print_subscription_keys
        if paused?
          yield if block_given?
        else
          subscribe { yield if block_given? }
        end

        loop do
          break unless @running
          detect_and_handle_a_pause
          instrument_thread_pool_sizes
          instrument_inflight_handlers
          thread_pool.replenish # respawn workers killed by non-StandardError
          sleep 1
        end

        unsubscribe

        logger.info "Shutting down subscription manager..."
        begin
          # No Timeout.timeout here. #shutdown already bounds itself with a
          # monotonic deadline and non-blocking pushes, and Timeout's async
          # Thread#raise is exactly what 0.13.1 removed from the manager: firing
          # it while a thread holds the SizedQueue mutex leaves JRuby unwinding
          # through a held mutex ("Attempt to unlock a mutex which is locked by
          # another thread"), which can then hang the queue for good.
          #
          # The wrapper could genuinely fire, too: #shutdown's own worst case
          # (one 1s push deadline per handler, then a 5s join, then 1s
          # kill-joins) exceeds 10s once there are more than a few handlers --
          # the JRuby default is processor_count.
          subscription_manager.shutdown(5)
        rescue => e
          logger.error "Error during subscription manager shutdown: #{e.message}"
        end

        # Give in-flight handlers time to finish. Long operations are allowed
        # (up to ~the client's response_timeout), so the drain timeout tracks
        # handler_overdue_ms rather than a fixed 60s -- otherwise a legitimate
        # ~60s handler would be killed and its client left waiting.
        drain_timeout = shutdown_drain_timeout
        logger.info "Waiting up to #{drain_timeout.round}s for the thread pool to finish shutting down..."
        thread_pool.shutdown
        unless thread_pool.wait_for_termination(drain_timeout)
          abandoned = @inflight.size
          logger.warn "Thread pool did not shut down cleanly within #{drain_timeout.round}s! Abandoned #{abandoned} in-flight handler(s)."
          ::Protobuf::Nats.instrument "server.thread_pool_shutdown_timeout"
          ::Protobuf::Nats.instrument "server.shutdown_abandoned_handlers", abandoned
        end
      ensure
        @stopped = true

        begin
          logger.info "Closing NATS connection..."
          @nats.close if @nats
        rescue => e
          logger.warn "Failed to close NATS connection: #{e.message}"
        end
      end

      def running?
        !@stopped
      end

      def stop
        @running = false
      end

      def subscribe
        subscribe_to_services_once
        yield if block_given?
        finish_slow_start
      end

      def unsubscribe
        logger.info "Unsubscribing from rpc routes..."
        subscription_manager.unsubscribe_all
      end
    end
  end
end
