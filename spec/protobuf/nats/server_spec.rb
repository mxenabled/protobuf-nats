require "spec_helper"

describe ::Protobuf::Nats::Server do
  class SomeRandom < ::Protobuf::Message; end
  class SomeRandomService < ::Protobuf::Rpc::Service
    rpc :implemented, SomeRandom, SomeRandom
    rpc :implemented_again, SomeRandom, SomeRandom
    rpc :not_implemented, SomeRandom, SomeRandom
    def implemented; end
    def implemented_again; end
  end

  let(:logger) { ::Logger.new(nil) }
  let(:client) { ::FakeNatsClient.new }
  let(:options) {
    {
      :threads => 2,
      :client  => client,
      :server  => 'derpaderp'
    }
  }

  subject { described_class.new(options) }

  # Keep one intake handler by default so these tests don't spawn processor_count
  # threads per subject; the fan-out itself is covered in the manager spec.
  around do |example|
    previous = ENV["PB_NATS_SERVER_SUBSCRIPTION_HANDLERS"]
    ENV["PB_NATS_SERVER_SUBSCRIPTION_HANDLERS"] = "1"
    example.run
    ENV["PB_NATS_SERVER_SUBSCRIPTION_HANDLERS"] = previous
  end

  before do
    allow(::Protobuf::Logging).to receive(:logger).and_return(logger)
    allow(subject).to receive(:service_klasses).and_return([SomeRandomService])
  end

  describe "#instrument_thread_pool_sizes" do
    it "instruments the thread pool enqueued size" do
      enqueued_size = nil
      subscription = ::ActiveSupport::Notifications.subscribe "server.thread_pool_enqueued_size.protobuf-nats" do |_, _, _, _, size|
        enqueued_size = size
      end

      subject.instrument_thread_pool_sizes
      expect(enqueued_size).to_not eq(nil)
      ::ActiveSupport::Notifications.unsubscribe(subscription)
    end

    it "instruments the thread pool max size" do
      max_size = nil
      subscription = ::ActiveSupport::Notifications.subscribe "server.thread_pool_max_size.protobuf-nats" do |_, _, _, _, size|
        max_size = size
      end

      subject.instrument_thread_pool_sizes
      expect(max_size).to_not eq(nil)
      ::ActiveSupport::Notifications.unsubscribe(subscription)
    end

    it "instruments the thread pool running size" do
      running_size = nil
      subscription = ::ActiveSupport::Notifications.subscribe "server.thread_pool_running_size.protobuf-nats" do |_, _, _, _, size|
        running_size = size
      end

      subject.instrument_thread_pool_sizes
      expect(running_size).to_not eq(nil)
      ::ActiveSupport::Notifications.unsubscribe(subscription)
    end
  end

  describe "#detect_and_handle_a_pause" do
    it "unsubscribes when the server is paused" do
      allow(subject).to receive(:paused?).and_return(true)
      expect(subject).to receive(:unsubscribe)
      subject.detect_and_handle_a_pause
    end

    it "subscribes and restarts slow start when the pause file is removed" do
      subject.instance_variable_set(:@processing_requests, false)
      expect(subject).to receive(:subscribe)
      subject.detect_and_handle_a_pause
    end

    it "never calls unsubscribe more than once per pause" do
      allow(subject).to receive(:paused?).and_return(true)
      expect(subject).to receive(:unsubscribe).once
      subject.detect_and_handle_a_pause
      subject.detect_and_handle_a_pause
      subject.detect_and_handle_a_pause
    end
    it "never calls subscribe more than once per pause" do
      subject.instance_variable_set(:@processing_requests, false)
      expect(subject).to receive(:subscribe).once
      subject.detect_and_handle_a_pause
      subject.detect_and_handle_a_pause
      subject.detect_and_handle_a_pause
    end
  end

  describe "#max_queue_size" do
    it "can be set via options hash" do
      expect(subject.max_queue_size).to eq(2)
    end

    it "can be set via PB_NATS_SERVER_MAX_QUEUE_SIZE environment variable" do
      ::ENV["PB_NATS_SERVER_MAX_QUEUE_SIZE"] = "10"

      expect(subject.max_queue_size).to eq(10)

      ::ENV.delete("PB_NATS_SERVER_MAX_QUEUE_SIZE")
    end
  end

  describe "#stale_request?" do
    # Build a syntactically valid UUIDv7 whose embedded timestamp is `time`.
    def uuidv7_at(time)
      ms = (time.to_f * 1000).to_i & 0xffffffffffff
      format("%08x-%04x-7%03x-%04x-%04x%08x",
             (ms >> 16) & 0xffffffff, ms & 0xffff, 0x123, 0x8123, 0x4567, 0x89abcdef)
    end

    def reply_id_for(token)
      "_INBOX.someprefix.#{token}"
    end

    it "is off by default (returns false even for an old token)" do
      expect(subject.stale_request?(reply_id_for(uuidv7_at(Time.now - 3600)))).to eq(false)
    end

    context "when PB_NATS_SERVER_STALE_REQUEST_MS is set" do
      around do |example|
        ::ENV["PB_NATS_SERVER_STALE_REQUEST_MS"] = "1000"
        example.run
      ensure
        ::ENV.delete("PB_NATS_SERVER_STALE_REQUEST_MS")
      end

      it "sheds a request older than the threshold and instruments it" do
        age_ms = nil
        subscription = ::ActiveSupport::Notifications.subscribe "server.stale_request_dropped.protobuf-nats" do |_, _, _, _, payload|
          age_ms = payload
        end

        expect(subject.stale_request?(reply_id_for(uuidv7_at(Time.now - 10)))).to eq(true)
        expect(age_ms).to be > 1000
        ::ActiveSupport::Notifications.unsubscribe(subscription)
      end

      it "keeps a fresh request" do
        expect(subject.stale_request?(reply_id_for(::Protobuf::Nats::UUIDv7Helper.generate))).to eq(false)
      end

      it "keeps a request whose reply token is not a UUIDv7 (foreign client)" do
        expect(subject.stale_request?(reply_id_for("aBcDeFnuidStyleToken00"))).to eq(false)
        expect(subject.stale_request?(nil)).to eq(false)
      end
    end
  end

  describe "pause_file_path" do
    it "is nil by default" do
      expect(subject.pause_file_path).to eq(nil)
    end

    it "can be set via PB_NATS_SERVER_PAUSE_FILE_PATH environment variable" do
      ::ENV["PB_NATS_SERVER_PAUSE_FILE_PATH"] = "/tmp/rpc-paused-bro"

      expect(subject.pause_file_path).to eq("/tmp/rpc-paused-bro")

      ::ENV.delete("PB_NATS_SERVER_PAUSE_FILE_PATH")
    end
  end

  describe "#paused?" do
    let(:test_file) { "#{::SecureRandom.uuid}-testing-123" }
    # Ensure the test file is always cleaned up.
    after { ::File.delete(test_file) if ::File.exist?(test_file) }

    it "pauses when a pause file is set" do
      ::ENV["PB_NATS_SERVER_PAUSE_FILE_PATH"] = test_file
      expect(subject).to_not be_paused
      ::File.write(test_file, "")
      expect(subject).to be_paused
      ::ENV.delete("PB_NATS_SERVER_PAUSE_FILE_PATH")
    end
  end

  describe "#slow_start_delay" do
    it "has a default" do
      expect(subject.slow_start_delay).to eq(10)
    end

    it "can be set via PB_NATS_SERVER_SLOW_START_DELAY environment variable" do
      ::ENV["PB_NATS_SERVER_SLOW_START_DELAY"] = "20"

      expect(subject.slow_start_delay).to eq(20)

      ::ENV.delete("PB_NATS_SERVER_SLOW_START_DELAY")
    end
  end

  describe "#subscriptions_per_rpc_endpoint" do
    it "has a default" do
      expect(subject.subscriptions_per_rpc_endpoint).to eq(10)
    end

    it "can be set via PB_NATS_SERVER_SUBSCRIPTIONS_PER_RPC_ENDPOINT environment variable" do
      ::ENV["PB_NATS_SERVER_SUBSCRIPTIONS_PER_RPC_ENDPOINT"] = "20"

      expect(subject.subscriptions_per_rpc_endpoint).to eq(20)

      ::ENV.delete("PB_NATS_SERVER_SUBSCRIPTIONS_PER_RPC_ENDPOINT")
    end
  end

  describe "#subscribe_to_services_once" do
    context "do not subscribe to when includes any of" do
      it "subscribes to services when they are not present" do
        config = ::Protobuf::Nats.config

        subject.subscribe_to_services_once
        expect(client.subscriptions.keys).to eq(["rpc.some_random_service.implemented", "rpc.some_random_service.implemented_again"])
      end

      it "does not subscribe when an included substring is present for an implemented service" do
        config = ::Protobuf::Nats.config
        config.server_subscription_key_do_not_subscribe_to_when_includes_any_of << "random_service"

        subject.subscribe_to_services_once
        expect(client.subscriptions.keys).to eq([])

        config.server_subscription_key_do_not_subscribe_to_when_includes_any_of.clear
      end

      it "does not subscribe when an included substring is present for an implemented service (and in only group)" do
        config = ::Protobuf::Nats.config
        config.server_subscription_key_do_not_subscribe_to_when_includes_any_of << "random_service"
        config.server_subscription_key_only_subscribe_to_when_includes_any_of << "random_service"

        subject.subscribe_to_services_once
        expect(client.subscriptions.keys).to eq([])

        config.server_subscription_key_do_not_subscribe_to_when_includes_any_of.clear
        config.server_subscription_key_only_subscribe_to_when_includes_any_of.clear
      end
    end

    context "only subscribe to when includes any of" do
      it "subscribes to services when they are not present" do
        config = ::Protobuf::Nats.config

        subject.subscribe_to_services_once
        expect(client.subscriptions.keys).to eq(["rpc.some_random_service.implemented", "rpc.some_random_service.implemented_again"])
      end

      it "subscribes when an included substring is present for an implemented service and restrains possible" do
        config = ::Protobuf::Nats.config
        config.server_subscription_key_only_subscribe_to_when_includes_any_of << "again"

        subject.subscribe_to_services_once
        expect(client.subscriptions.keys).to eq(["rpc.some_random_service.implemented_again"])

        config.server_subscription_key_only_subscribe_to_when_includes_any_of.clear
      end

      it "subscribes when an included substring is present for an implemented service" do
        config = ::Protobuf::Nats.config
        config.server_subscription_key_only_subscribe_to_when_includes_any_of << "random_service"

        subject.subscribe_to_services_once
        expect(client.subscriptions.keys).to eq(["rpc.some_random_service.implemented", "rpc.some_random_service.implemented_again"])

        config.server_subscription_key_only_subscribe_to_when_includes_any_of.clear
      end

      it "does not subscribe when an included substring is present for an implemented service (and in do not group)" do
        config = ::Protobuf::Nats.config
        config.server_subscription_key_do_not_subscribe_to_when_includes_any_of << "random_service"
        config.server_subscription_key_only_subscribe_to_when_includes_any_of << "random_service"

        subject.subscribe_to_services_once
        expect(client.subscriptions.keys).to eq([])

        config.server_subscription_key_do_not_subscribe_to_when_includes_any_of.clear
        config.server_subscription_key_only_subscribe_to_when_includes_any_of.clear
      end
    end

    it "subscribes to services that inherit from protobuf rpc service" do
      subject.subscribe_to_services_once
      expect(client.subscriptions.keys).to eq(["rpc.some_random_service.implemented", "rpc.some_random_service.implemented_again"])
    end
  end

  describe "#enqueue_request" do
    it "returns false when the thread pool and thread pool queue is full and publish NACK" do
      # Fill the thread pool.
      2.times { subject.thread_pool.push { sleep 1 } }
      # Fill the thread pool queue.
      2.times { subject.thread_pool.push { sleep 1 } }

      expect(subject.nats).to receive(:publish).with("inbox_123", ::Protobuf::Nats::Messages::NACK)
      expect(subject.enqueue_request("", "inbox_123")).to eq(false)
    end

    it "logs a thread pool is full error when subscription manager processes a message but the thread pool is full" do
      # Fill the thread pool and its queue.
      2.times { subject.thread_pool.push { sleep 1 } }
      2.times { subject.thread_pool.push { sleep 1 } }

      # Expect NACK to be published when enqueue_request is called
      expect(subject.nats).to receive(:publish).with("inbox_123", ::Protobuf::Nats::Messages::NACK)

      # Expect the logger to log a thread pool is full error
      expect(logger).to receive(:error) do |&block|
        expect(block.call).to match(/Thread pool is full! Dropping message for subject: rpc.some_subject/)
      end

      # Deliver the message by putting it into subscription manager's queue
      message = double(:data => "req_data", :reply => "inbox_123", :subject => "rpc.some_subject")
      pending_queue = subject.subscription_manager.instance_variable_get(:@pending_queue)
      pending_queue.push(message)

      # Give the subscription manager thread a tiny bit of time to pop and execute
      sleep 0.1

      # Cleanup
      subject.thread_pool.kill
      subject.subscription_manager.shutdown(0.1)
    end

    it "sends an ACK if the thread pool enqueued the task" do
      # Fill the thread pool.
      2.times { subject.thread_pool.push { sleep 1 } }
      expect(subject.nats).to receive(:publish).with("inbox_123", ::Protobuf::Nats::Messages::ACK)
      # Wait for promise to finish executing.
      expect(subject.enqueue_request("", "inbox_123")).to eq(true)
      subject.thread_pool.kill
    end

    it "logs any error that is raised within the request block" do
      request_data = "yolo"
      expect(subject).to receive(:handle_request).with(request_data, 'server' => 'derpaderp').and_raise(::RuntimeError, "mah error")
      expect(logger).to receive(:error).once.ordered.with("mah error")
      expect(logger).to receive(:error).once.ordered.with("RuntimeError")
      expect(logger).to receive(:error).once.ordered

      # Wait for promise to finish executing.
      expect(subject.enqueue_request(request_data, "inbox_123")).to eq(true)
      sleep 0.1 until subject.thread_pool.size.zero?
    end

    it "returns an ACK and a response" do
      response = "some response data"
      inbox = "inbox_123"
      expect(subject).to receive(:handle_request).and_return(response)

      # The ACK is published on the intake thread and the response on a worker
      # thread, so their order is NOT guaranteed (the client muxer accepts either
      # order). Record both via a thread-safe Queue and assert order-independently.
      published = ::Queue.new
      allow(client).to receive(:publish) { |reply_id, data| published << [reply_id, data] }

      expect(subject.enqueue_request("", inbox)).to eq(true)
      wait_until { published.size >= 2 }

      got = []
      got << published.pop until published.empty?
      expect(got).to contain_exactly(
        [inbox, ::Protobuf::Nats::Messages::ACK],
        [inbox, response],
      )
    end

    # Negative: when handling the request fails after the ACK was sent, the
    # client is blocked waiting for a response. The server must publish an
    # encoded RPC error so the client fails fast instead of hanging until
    # response_timeout.
    it "publishes a generic encoded RPC error response when the request handler raises" do
      inbox = "inbox_123"
      allow(::Protobuf::Nats).to receive(:notify_error_callbacks)
      expect(subject).to receive(:handle_request).and_raise(::RuntimeError, "boom")

      # ACK (intake thread) and error response (worker thread) race; record both
      # via a thread-safe Queue and assert order-independently.
      published = ::Queue.new
      allow(client).to receive(:publish) { |reply_id, data| published << [reply_id, data] }

      expect(subject.enqueue_request("req", inbox)).to eq(true)
      wait_until { published.size >= 2 }

      got = []
      got << published.pop until published.empty?
      expect(got).to include([inbox, ::Protobuf::Nats::Messages::ACK])

      error_payload = got.find { |reply_id, data| reply_id == inbox && data != ::Protobuf::Nats::Messages::ACK }&.last
      expect(error_payload).not_to be_nil
      decoded = ::Protobuf::Socketrpc::Response.decode(error_payload)
      # Generic message -- internal handler details ("boom") are not leaked.
      expect(decoded.error).to eq("Internal server error")
      expect(decoded.error).not_to include("boom")
      expect(decoded.error_reason).to eq(::Protobuf::Socketrpc::ErrorReason::RPC_ERROR)
    end

    it "does not raise when publishing the error response also fails" do
      inbox = "inbox_123"
      allow(::Protobuf::Nats).to receive(:notify_error_callbacks)
      expect(subject).to receive(:handle_request).and_raise(::RuntimeError, "boom")
      # Any publish blows up (e.g. connection dropped) except the ACK, which we
      # let through so the failure happens on the error-response publish.
      allow(client).to receive(:publish).and_raise(::Errno::ECONNRESET)
      allow(client).to receive(:publish).with(inbox, ::Protobuf::Nats::Messages::ACK)
      expect(logger).to receive(:error).with(/Failed to publish error response/)

      expect { subject.enqueue_request("req", inbox) }.not_to raise_error
      sleep 0.1 until subject.thread_pool.size.zero?
    end

    it "does not emit a duplicate error response when the success-response publish fails" do
      inbox = "inbox_pub_fail"
      allow(::Protobuf::Nats).to receive(:notify_error_callbacks)
      expect(subject).to receive(:handle_request).and_return("ok")
      allow(logger).to receive(:error)

      publishes = []
      allow(client).to receive(:publish) do |reply_id, data|
        publishes << [reply_id, data]
        raise ::Errno::ECONNRESET if data == "ok" # only the response publish fails
      end
      expect(logger).to receive(:error).with(/Failed to publish response/)

      expect(subject.enqueue_request("req", inbox)).to eq(true)
      sleep 0.1 until subject.thread_pool.size.zero?

      # The only publishes to the reply inbox are the ACK and the (failed)
      # response attempt -- NOT a follow-up PbError for a request that succeeded.
      extra = publishes.select do |reply_id, data|
        reply_id == inbox && data != ::Protobuf::Nats::Messages::ACK && data != "ok"
      end
      expect(extra).to be_empty
    end
  end

  describe "#shutdown_drain_timeout" do
    it "defaults above the handler overdue window so long handlers can finish" do
      expect(subject.shutdown_drain_timeout).to be > (subject.handler_overdue_ms / 1000.0)
    end

    it "is configurable via PB_NATS_SERVER_SHUTDOWN_DRAIN_TIMEOUT" do
      ENV["PB_NATS_SERVER_SHUTDOWN_DRAIN_TIMEOUT"] = "12.5"
      expect(subject.shutdown_drain_timeout).to eq(12.5)
    ensure
      ENV.delete("PB_NATS_SERVER_SHUTDOWN_DRAIN_TIMEOUT")
    end
  end

  describe "handler observability" do
    def capture(event)
      seen = []
      sub = ::ActiveSupport::Notifications.subscribe(event) { |_, _, _, _, payload| seen << payload }
      yield
      ::ActiveSupport::Notifications.unsubscribe(sub)
      seen
    end

    it "allows a long-running handler to complete without aborting or flagging it" do
      # Defaults: slow=off, overdue=65s. A handler that runs a while is normal.
      inbox = "inbox_long"
      allow(subject).to receive(:handle_request) { sleep 0.3; "done" }

      slow = capture("server.slow_handler.protobuf-nats") do
        expect(client).to receive(:publish).with(inbox, ::Protobuf::Nats::Messages::ACK)
        expect(client).to receive(:publish).with(inbox, "done") # completed, not aborted
        subject.enqueue_request("req", inbox)
        sleep 0.1 until subject.thread_pool.size.zero?
      end

      expect(slow).to be_empty
    end

    it "emits server.slow_handler only when the slow threshold is exceeded" do
      ENV["PB_NATS_SERVER_SLOW_HANDLER_THRESHOLD_MS"] = "1"
      allow(subject).to receive(:handle_request) { sleep 0.05; "ok" }

      slow = capture("server.slow_handler.protobuf-nats") do
        subject.enqueue_request("req", "inbox")
        sleep 0.1 until subject.thread_pool.size.zero?
      end

      expect(slow.size).to eq(1)
      expect(slow.first).to be >= 1
    ensure
      ENV.delete("PB_NATS_SERVER_SLOW_HANDLER_THRESHOLD_MS")
    end

    it "tracks in-flight handlers and clears them on completion" do
      release = ::Queue.new
      allow(subject).to receive(:handle_request) { release.pop; "ok" }
      allow(client).to receive(:publish)

      subject.enqueue_request("req", "inbox")
      # Wait for the worker to actually start and register in-flight (don't race a
      # fixed sleep against thread scheduling).
      wait_until { subject.instance_variable_get(:@inflight).size >= 1 }

      inflight = capture("server.inflight_count.protobuf-nats") { subject.instrument_inflight_handlers }
      expect(inflight.last).to be >= 1

      release << :go
      sleep 0.1 until subject.thread_pool.size.zero?

      cleared = capture("server.inflight_count.protobuf-nats") { subject.instrument_inflight_handlers }
      expect(cleared.last).to eq(0)
    end

    it "flags an overdue handler past the window but counts a long-but-not-overdue one as in-flight only" do
      ENV["PB_NATS_SERVER_HANDLER_OVERDUE_MS"] = "50"
      release = ::Queue.new
      allow(subject).to receive(:handle_request) { release.pop; "ok" }
      allow(client).to receive(:publish)

      subject.enqueue_request("req", "inbox")
      # Wait for in-flight registration, then exceed the 50ms overdue window while
      # the handler is still blocked.
      wait_until { subject.instance_variable_get(:@inflight).size >= 1 }
      sleep 0.07

      overdue_events = capture("server.handler_overdue.protobuf-nats") do
        @overdue_count = capture("server.overdue_handler_count.protobuf-nats") do
          subject.instrument_inflight_handlers
        end
      end

      expect(overdue_events.size).to eq(1)
      expect(@overdue_count.last).to be >= 1
    ensure
      release << :go
      ENV.delete("PB_NATS_SERVER_HANDLER_OVERDUE_MS")
      sleep 0.1 until subject.thread_pool.size.zero?
    end

    it "does not abort an overdue handler by default (handlers are never aborted)" do
      ENV["PB_NATS_SERVER_HANDLER_OVERDUE_MS"] = "50"
      release = ::Queue.new
      allow(subject).to receive(:handle_request) { release.pop; "ok" }
      allow(client).to receive(:publish)

      subject.enqueue_request("req", "inbox")
      wait_until { subject.instance_variable_get(:@inflight).size >= 1 }
      sleep 0.07 # exceed the overdue window while still in-flight

      reclaimed = capture("server.handler_reclaimed.protobuf-nats") do
        subject.instrument_inflight_handlers
      end

      # Flagged overdue, but not reclaimed -- it stays in-flight until released.
      expect(reclaimed).to be_empty
      expect(subject.thread_pool.size).to be >= 1
    ensure
      release << :go
      ENV.delete("PB_NATS_SERVER_HANDLER_OVERDUE_MS")
      sleep 0.1 until subject.thread_pool.size.zero?
    end

    it "reclaims an overdue handler when PB_NATS_SERVER_RECLAIM_OVERDUE_HANDLERS is enabled" do
      ENV["PB_NATS_SERVER_HANDLER_OVERDUE_MS"] = "50"
      ENV["PB_NATS_SERVER_RECLAIM_OVERDUE_HANDLERS"] = "true"
      release = ::Queue.new
      # Blocks until released OR until HandlerOverdue is raised into the thread.
      allow(subject).to receive(:handle_request) { release.pop; "ok" }
      allow(client).to receive(:publish)

      subject.enqueue_request("req", "inbox")
      wait_until { subject.instance_variable_get(:@inflight).size >= 1 }
      sleep 0.07 # exceed the overdue window while still in-flight

      reclaimed = capture("server.handler_reclaimed.protobuf-nats") do
        subject.instrument_inflight_handlers
      end

      expect(reclaimed.size).to eq(1)
      # The handler thread was aborted, so the pool drains without releasing it.
      wait_until(timeout: 2) { subject.thread_pool.size.zero? }
    ensure
      release << :go rescue nil
      ENV.delete("PB_NATS_SERVER_HANDLER_OVERDUE_MS")
      ENV.delete("PB_NATS_SERVER_RECLAIM_OVERDUE_HANDLERS")
    end

    it "reaps orphaned overdue flags whose handler is no longer in-flight" do
      inflight = subject.instance_variable_get(:@inflight)
      overdue_flagged = subject.instance_variable_get(:@overdue_flagged)

      # An overdue flag left behind by the set-after-ensure-delete race: its id
      # is not in @inflight, so nothing else would ever remove it.
      overdue_flagged[:orphan] = true
      # A flag for a still-in-flight handler must be preserved.
      inflight[:live] = [subject.send(:monotonic), ::Thread.current]
      overdue_flagged[:live] = true

      subject.instrument_inflight_handlers

      expect(overdue_flagged.key?(:orphan)).to be(false)
      expect(overdue_flagged.key?(:live)).to be(true)
    ensure
      inflight.delete(:live)
      overdue_flagged.delete(:live)
    end

    it "emits server.thread_pool_saturated and NACKs when the pool is full" do
      # Fill the pool + queue (threads: 2, max_queue defaults to threads).
      4.times { subject.thread_pool.push { sleep 1 } }

      allow(client).to receive(:publish)
      saturated = capture("server.thread_pool_saturated.protobuf-nats") do
        expect(client).to receive(:publish).with("inbox", ::Protobuf::Nats::Messages::NACK)
        expect(subject.enqueue_request("", "inbox")).to eq(false)
      end

      expect(saturated.size).to eq(1)
      subject.thread_pool.kill
    end
  end

  describe "instrumentation" do
    it "instruments the thread pool execution delay" do
      expect(subject).to receive(:handle_request).and_return("response")
      execution_delay = nil
      subscription = ::ActiveSupport::Notifications.subscribe "server.thread_pool_execution_delay.protobuf-nats" do |_, _, _, _, delay|
        execution_delay = delay
      end

      subject.enqueue_request("", "YOLO123")
      sleep 0.1 until subject.thread_pool.size.zero?

      expect(execution_delay).to_not eq(nil)
      ::ActiveSupport::Notifications.unsubscribe(subscription)
    end

    it "instrument a request duration" do
      expect(subject).to receive(:handle_request) do
        sleep 0.05
        "response"
      end
      request_duration = nil
      subscription = ::ActiveSupport::Notifications.subscribe "server.request_duration.protobuf-nats" do |_, _, _, _, duration|
        request_duration = duration
      end

      subject.enqueue_request("", "YOLO123")
      sleep 0.1 until subject.thread_pool.size.zero?

      expect(request_duration).to be >= 0.05
      ::ActiveSupport::Notifications.unsubscribe(subscription)
    end

    it "instruments when a message received" do
      allow(subject.thread_pool).to receive(:push)
      message_was_received = false
      subscription = ::ActiveSupport::Notifications.subscribe "server.message_received.protobuf-nats" do
        message_was_received = true
      end

      subject.enqueue_request("", "YOLO123")
      sleep 0.1 until subject.thread_pool.size.zero?

      expect(message_was_received).to eq(true)
      ::ActiveSupport::Notifications.unsubscribe(subscription)
    end

    it "instruments when a message dropped" do
      allow(subject.thread_pool).to receive(:push).and_return(false)
      message_was_dropped = false
      subscription = ::ActiveSupport::Notifications.subscribe "server.message_dropped.protobuf-nats" do
        message_was_dropped = true
      end

      subject.enqueue_request("", "YOLO123")
      sleep 0.1 until subject.thread_pool.size.zero?

      expect(message_was_dropped).to eq(true)
      ::ActiveSupport::Notifications.unsubscribe(subscription)
    end
  end

  describe "edge cases and fixes" do
    describe "#running?" do
      it "returns true when server is running" do
        expect(subject.instance_variable_get(:@stopped)).to be(false)
        expect(subject.running?).to be(true)
      end

      it "returns false when server is stopped" do
        subject.instance_variable_set(:@stopped, true)
        expect(subject.running?).to be(false)
      end
    end

    describe "ACK/NACK error handling" do
      it "handles NATS publish errors when sending ACK" do
        allow(subject.thread_pool).to receive(:push).and_return(true)
        allow(client).to receive(:publish).and_raise(StandardError, "NATS disconnected")

        # Expect error to be logged
        expect(logger).to receive(:error).at_least(:once)

        # Should not raise, just log
        expect { subject.enqueue_request("data", "reply123") }.not_to raise_error
      end

      it "handles NATS publish errors when sending NACK" do
        allow(subject.thread_pool).to receive(:push).and_return(false)
        allow(client).to receive(:publish).and_raise(StandardError, "NATS disconnected")

        # Expect error to be logged
        expect(logger).to receive(:error).at_least(:once)

        # Should not raise, just log
        expect { subject.enqueue_request("data", "reply123") }.not_to raise_error
      end
    end

    describe "#finish_slow_start" do
      before do
        allow(subject).to receive(:subscribe_to_services_once)
        allow(subject).to receive(:sleep)
      end

      it "logs successful completion" do
        # Allow any info logs, then verify the specific one was called
        allow(logger).to receive(:info)
        subject.finish_slow_start
        expect(logger).to have_received(:info).with(/slow start finished successfully/i)
      end

      it "exits early and logs when server is stopping" do
        # Stop after first iteration
        allow(subject).to receive(:slow_start_delay).and_return(0)
        call_count = 0
        allow(subject).to receive(:subscribe_to_services_once) do
          call_count += 1
          subject.instance_variable_set(:@running, false) if call_count == 1
        end

        expect(logger).to receive(:info).with(/slow start interrupted.*stopping/i)
        expect(logger).not_to receive(:info).with(/finished successfully/i)

        subject.finish_slow_start
      end

      it "exits early and logs when server is paused" do
        allow(subject).to receive(:paused?).and_return(false, true)
        allow(subject).to receive(:slow_start_delay).and_return(0)

        expect(logger).to receive(:info).with(/slow start interrupted.*paused/i)
        expect(logger).not_to receive(:info).with(/finished successfully/i)

        subject.finish_slow_start
      end
    end

    describe "#detect_and_handle_a_pause" do
      it "is thread-safe with mutex" do
        # Verify mutex exists
        expect(subject.instance_variable_get(:@pause_mutex)).to be_a(Mutex)

        # Simulate concurrent calls
        threads = 10.times.map do
          Thread.new { subject.detect_and_handle_a_pause }
        end

        threads.each(&:join)

        # No exceptions should be raised
      end

      it "handles pause/resume transitions safely" do
        allow(subject).to receive(:paused?).and_return(true)
        allow(subject).to receive(:unsubscribe)

        # First call should unsubscribe
        subject.detect_and_handle_a_pause
        expect(subject.instance_variable_get(:@processing_requests)).to be(false)

        # Resume
        allow(subject).to receive(:paused?).and_return(false)
        allow(subject).to receive(:subscribe)

        subject.detect_and_handle_a_pause
        expect(subject.instance_variable_get(:@processing_requests)).to be(true)
      end
    end

    describe "connection lifecycle" do
      it "registers all lifecycle callbacks at initialize, before connect" do
        subject # force initialize
        expect(client.callbacks.keys).to match_array(%i[disconnect reconnect error close])
      end

      it "stops the server when the connection closes unexpectedly (reconnects exhausted)" do
        subject # force initialize so callbacks are registered
        instrumented = false
        subscription = ::ActiveSupport::Notifications.subscribe("server.connection_closed.protobuf-nats") do
          instrumented = true
        end
        expect(logger).to receive(:error).with(/closed unexpectedly/i)

        client.fire_callback(:close)

        expect(subject.instance_variable_get(:@running)).to be(false)
        expect(instrumented).to be(true)
      ensure
        ::ActiveSupport::Notifications.unsubscribe(subscription)
      end

      it "does not treat a close during graceful shutdown as a failure" do
        subject.stop
        instrumented = false
        subscription = ::ActiveSupport::Notifications.subscribe("server.connection_closed.protobuf-nats") do
          instrumented = true
        end
        expect(logger).not_to receive(:error)

        client.fire_callback(:close)

        expect(instrumented).to be(false)
      ensure
        ::ActiveSupport::Notifications.unsubscribe(subscription)
      end
    end

    describe "shutdown sequence" do
      before do
        # Stub NATS callback methods
        allow(client).to receive(:on_reconnect)
        allow(client).to receive(:on_disconnect)
        allow(client).to receive(:on_error)
        allow(client).to receive(:on_close)
        allow(client).to receive(:close)
      end

      it "closes NATS connection on shutdown" do
        # Mock the run loop to exit immediately without sleeping
        allow(subject).to receive(:loop)
        allow(subject).to receive(:print_subscription_keys)
        allow(subject).to receive(:subscribe)
        allow(subject).to receive(:unsubscribe)

        # Expect NATS to be closed
        expect(client).to receive(:close)

        # Stop immediately - no need for thread and sleep
        subject.instance_variable_set(:@running, false)
        subject.run
      end

      it "logs and continues when subscription manager shutdown raises" do
        # Mock the run loop to exit immediately
        allow(subject).to receive(:loop)
        allow(subject).to receive(:print_subscription_keys)
        allow(subject).to receive(:subscribe)
        allow(subject).to receive(:unsubscribe)

        allow(subject.subscription_manager).to receive(:shutdown).and_raise(::RuntimeError, "boom")

        # Allow any error logs
        allow(logger).to receive(:error)
        allow(logger).to receive(:info)
        allow(logger).to receive(:warn)

        subject.instance_variable_set(:@running, false)
        subject.run

        expect(logger).to have_received(:error).with(/Error during subscription manager shutdown: boom/)
      end

      # Regression: 0.13.1 removed Timeout.timeout from SuperSubscriptionManager
      # because its async Thread#raise corrupts the SizedQueue mutex on JRuby,
      # but left a Timeout.timeout(10) wrapper around the whole shutdown call --
      # reintroducing the same hazard one frame up. #shutdown self-bounds, so
      # there must be no Timeout around it.
      it "does not wrap subscription manager shutdown in Timeout.timeout" do
        allow(subject).to receive(:loop)
        allow(subject).to receive(:print_subscription_keys)
        allow(subject).to receive(:subscribe)
        allow(subject).to receive(:unsubscribe)
        allow(subject.subscription_manager).to receive(:shutdown)
        allow(logger).to receive(:error)
        allow(logger).to receive(:info)
        allow(logger).to receive(:warn)

        expect(::Timeout).not_to receive(:timeout)

        subject.instance_variable_set(:@running, false)
        subject.run
      end

      it "handles thread pool shutdown timeout" do
        # Mock the run loop to exit immediately
        allow(subject).to receive(:loop)
        allow(subject).to receive(:print_subscription_keys)
        allow(subject).to receive(:subscribe)
        allow(subject).to receive(:unsubscribe)

        # Make thread pool wait return false immediately (simulating timeout)
        allow(subject.thread_pool).to receive(:shutdown)
        allow(subject.thread_pool).to receive(:wait_for_termination).and_return(false)

        # Allow any logs
        allow(logger).to receive(:warn)
        allow(logger).to receive(:info)

        # Should instrument the timeout
        timeout_instrumented = false
        subscription = ::ActiveSupport::Notifications.subscribe "server.thread_pool_shutdown_timeout.protobuf-nats" do
          timeout_instrumented = true
        end

        subject.instance_variable_set(:@running, false)
        subject.run

        expect(timeout_instrumented).to be(true)
        expect(logger).to have_received(:warn).with(/thread pool did not shut down cleanly/i)
        ::ActiveSupport::Notifications.unsubscribe(subscription)
      end
    end

    describe "typo fixes" do
      it "spells 'Publishing' correctly in log" do
        allow(subject.thread_pool).to receive(:push).and_yield.and_return(true)
        allow(subject).to receive(:handle_request).and_return("response")
        allow(client).to receive(:publish)

        # Capture debug log calls
        debug_messages = []
        allow(logger).to receive(:debug) do |&block|
          debug_messages << (block ? block.call : nil)
        end

        subject.enqueue_request("data", "reply123")

        # Verify the correct spelling was used
        expect(debug_messages.any? { |msg| msg =~ /Publishing response/i }).to be(true)
      end
    end
  end
end
