require "concurrent"
require "protobuf/nats/errors"

module Protobuf
  module Nats
    class ThreadPool

      def initialize(size, opts = {})
        @queue = ::Queue.new
        # Lock-free counter of in-flight work. Replaces a mutex-guarded integer so
        # that N workers running in true parallel (JRuby) don't serialize on every
        # task completion.
        @active_work = ::Concurrent::AtomicFixnum.new(0)

        # Callbacks
        @error_cb = lambda do |error|
          logger.error("Error in ThreadPool worker: #{error.message}
 #{error.backtrace.join("
")}")
        end

        # Synchronization
        @mutex = ::Mutex.new      # guards the @workers array only
        @cb_mutex = ::Mutex.new

        # Let's get this party started
        queue_size = opts[:max_queue].to_i || 0
        @max_size = size + queue_size
        @max_workers = size
        @shutting_down = ::Concurrent::AtomicBoolean.new(false)
        @workers = []
        supervise_workers
      end

      def enqueued_size
        @queue.size
      end

      # Thread-safe access to check if the pool is full.
      def full?
        @active_work.value >= @max_size
      end

      def max_size
        @max_size
      end

      # This method is now thread-safe.
      def push(&work_cb)
        return false if @shutting_down.true?

        # Optimistically claim a slot; back off if we exceeded the cap. This admits
        # work only while active_work < max_size, matching the original guard, but
        # without holding a mutex across the enqueue.
        if @active_work.increment > @max_size
          @active_work.decrement
          return false
        end

        @queue << [:work, work_cb]
        true
      end

      # This method is now thread-safe.
      def shutdown
        # CAS ensures the poison pills are pushed exactly once.
        return unless @shutting_down.make_true

        @max_workers.times { @queue << [:stop, nil] }
      end

      def kill
        @shutting_down.make_true
        @workers.map(&:kill)
      end

      # Wait until all workers exit. Returns true if the pool drained, false if
      # the timeout elapsed first. Prunes under the mutex (it mutates @workers).
      def wait_for_termination(seconds = nil)
        deadline = seconds && (::Protobuf::Nats.monotonic_time + seconds)
        loop do
          @mutex.synchronize { prune_dead_workers }
          if @workers.empty?
            # Workers drain what is behind their poison pill, but a push that
            # had already passed the @shutting_down check can land after the
            # last worker has drained and exited. Nothing would ever run it,
            # and the server has already ACKed it. Run it here, on the caller's
            # thread, now that no worker is left to race us.
            drain_remaining_work
            return true
          end
          return false if deadline && ::Protobuf::Nats.monotonic_time >= deadline
          sleep 0.1
        end
      end

      # Top the pool back up to max_workers if workers have died (e.g. one was
      # killed by a non-StandardError, which the per-task rescue can't catch).
      # This is the ONLY respawn path after initialize -- #push deliberately
      # does not supervise (a mutex acquisition plus an O(workers) alive? scan
      # per request is contention on the hot enqueue path); the server's run
      # loop calls this every second, so a dead worker is replaced within ~1s
      # and its queued work is picked up then.
      # No-op while shutting down so we don't resurrect workers mid-drain.
      def replenish
        return if @shutting_down.true?
        supervise_workers
      end

      # This callback is executed in a thread safe manner.
      def on_error(&cb)
        @cb_mutex.synchronize { @error_cb = cb }
      end

      # Thread-safe access to the current active work size.
      def size
        @active_work.value
      end

    private

      def logger
        ::Protobuf::Logging.logger
      end

      def prune_dead_workers
        # This must be called inside @mutex.
        @workers = @workers.select(&:alive?)
      end

      def supervise_workers
        @mutex.synchronize do
          prune_dead_workers
          missing_worker_count = (@max_workers - @workers.size)
          missing_worker_count.times do
            @workers << spawn_worker
          end
        end
      end

      # Run any :work left in the queue behind a poison pill, then stop. Called
      # by a worker that has taken its pill, and once more by
      # #wait_for_termination after the last worker exits (a push that already
      # passed the @shutting_down check can land after every worker has gone).
      #
      # This does not make admission and shutdown atomic -- #push is lock-free
      # by design, so work can still arrive after the final drain. It closes the
      # window that matters: everything enqueued up to the moment the pool
      # reports termination runs, so no ACKed request is silently dropped.
      def drain_remaining_work
        loop do
          begin
            type, cb = @queue.pop(true) # non_block: empty queue ends the drain
          rescue ::ThreadError
            break
          end

          # Another worker's pill: put it back so that worker still exits, and
          # stop draining (the remaining pills are theirs, not ours).
          if type == :stop
            @queue << [:stop, nil]
            break
          end

          begin
            cb.call
          rescue => error
            @cb_mutex.synchronize { @error_cb.call(error) }
          ensure
            @active_work.decrement
          end
        end
      end

      def spawn_worker
        ::Thread.new do
          Thread.current.name = "thread-pool-worker"
          loop do
            begin
              type, cb = @queue.pop
            rescue ::Protobuf::Nats::Errors::HandlerOverdue
              # A late overdue-reclaim raise (opt-in server feature) can land
              # while the worker is parked between tasks; swallow it rather
              # than losing the worker until the next replenish tick.
              next
            end

            # The :stop poison pill never claimed an @active_work slot (see
            # #shutdown), so it must not reach the ensure below -- decrementing
            # for it drove the counter negative at shutdown.
            if type == :stop
              # #push admits work by checking @shutting_down and then enqueueing,
              # so #shutdown can slip its pills in between those two steps and
              # leave real work sitting BEHIND them. Exiting here would strand
              # that work forever -- and the server has already published an ACK
              # for it, so its client blocks until response_timeout (60s).
              #
              # Drain what is behind us before leaving. Pop non-blocking so an
              # empty queue ends the drain immediately; hand any sibling's pill
              # back so every worker still gets one.
              drain_remaining_work
              break
            end

            begin
              cb.call
            rescue => error
              @cb_mutex.synchronize { @error_cb.call(error) }
            ensure
              @active_work.decrement
            end
          end
        end
      end

    end
  end
end
