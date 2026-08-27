require "concurrent"

module Protobuf
  module Nats
    # A SizedQueue that additionally bounds the total *bytes* of its contents,
    # not just the message count. The server funnels every subscription into one
    # shared intake queue, so a per-subscription byte limit (nats-pure's
    # pending_bytes_limit) can't bound the aggregate heap -- this shared counter
    # can. Count is still bounded by the SizedQueue capacity it inherits.
    #
    # When a push would exceed the byte ceiling we DROP the message rather than
    # block: pushes happen on nats-pure's read thread (Subscription#dispatch), and
    # blocking it would stall PING/PONG and every other subject. A drop mirrors
    # nats-pure's own SlowConsumer behaviour. Non-message items (the :shutdown
    # poison pill) carry zero bytes, so they are never dropped by the byte gate.
    #
    # A drop invokes the optional +on_drop+ callback with the dropped byte count,
    # so the caller owns any (context-specific) instrumentation rather than this
    # generic queue class hard-coding it.
    class ByteBoundedQueue < ::SizedQueue
      def initialize(max_msgs, max_bytes, on_drop: nil)
        super(max_msgs)
        @max_bytes = max_bytes
        @on_drop = on_drop
        @bytes = ::Concurrent::AtomicFixnum.new(0)
      end

      # Enqueue unless it would exceed the byte ceiling. The check-then-add races
      # only concurrent pops (which lower @bytes), so the ceiling can be exceeded
      # by at most one in-flight message -- a soft limit, like nats-pure's own
      # byte accounting. Returns self (SizedQueue#push contract). Raises
      # ThreadError from super on a non_block push into a count-full queue; the
      # bytes counted for that attempt are rolled back before it propagates.
      def push(obj, non_block = false)
        bytes = byte_size(obj)
        if bytes > 0 && (@bytes.value + bytes) > @max_bytes
          @on_drop&.call(bytes)
          return self
        end

        # Count the bytes BEFORE the enqueue, and roll back if the enqueue does
        # not happen. Counting after `super` lets a consumer pop the object and
        # subtract its bytes before this thread has added them; #pop's clamp at
        # zero then swallows that subtraction, and the increment that lands
        # afterwards becomes a permanent overcount for a message that is already
        # gone. The counter only ever ratchets up, and once it reaches
        # @max_bytes every later push is dropped forever -- the same drift class
        # as the nats-pure pending_size bug.
        #
        # A blocking push (non_block false, count-full queue) leaves the bytes
        # counted while we wait. That is a deliberate short overcount: it errs
        # toward dropping rather than admitting, and it resolves as soon as the
        # push completes or rolls back.
        @bytes.increment(bytes) if bytes > 0
        pushed = false
        begin
          super(obj, non_block)
          pushed = true
        ensure
          # ensure (not rescue) so an async Thread#raise or a non-StandardError
          # unwind rolls the counter back too.
          @bytes.decrement(bytes) if bytes > 0 && !pushed
        end
        self
      end
      alias_method :<<, :push

      def pop(non_block = false)
        obj = super
        # nil == closed/empty non_block; nothing dequeued, nothing to subtract.
        # The clamp at zero is only a backstop for #clear racing an in-flight
        # pop (clear zeroes the counter, then the pop subtracts). #push counts
        # bytes before enqueueing, so a normal pop always has its bytes present.
        @bytes.update { |value| [value - byte_size(obj), 0].max } if obj
        obj
      end

      def clear
        super
        @bytes.value = 0
      end

      # Current resident byte total (gauge for observability).
      def bytesize
        @bytes.value
      end

      private

      # Bytes attributable to a queued item. NATS::Msg carries #data; the
      # :shutdown poison pill (and any other non-message sentinel) counts as 0.
      def byte_size(obj)
        obj.respond_to?(:data) && obj.data ? obj.data.bytesize : 0
      end
    end
  end
end
