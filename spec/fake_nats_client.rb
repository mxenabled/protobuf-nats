require "securerandom"
require "thread"

class FakeNatsClient
  Message = Struct.new(:subject, :data, :seconds_in_future)

  attr_reader :subscriptions

  def initialize(options = {})
    @inbox = options[:inbox] || ::SecureRandom.uuid
    @subscriptions = {}
  end

  def connect(*)
  end

  def new_inbox
    @inbox
  end

  def publish(*)
  end

  def flush
  end

  def subscribe(subject, args = {}, &block)
    s = ::NATS::Subscription.new
    s.pending_queue = ::SizedQueue.new(1024)

    subscriptions[subject] = {:block => block, :subscription => s }

    s
  end

  def unsubscribe(*)
  end

  def next_message(_sub, timeout)
    started_at = ::Time.now
    @next_message = nil
    sleep 0.001 while @next_message.nil? && timeout > (::Time.now - started_at)
    @next_message
  end

  def schedule_message(message)
    schedule_messages([message])
  end

  def schedule_messages(messages)
    messages.each do |message|
      Thread.new do
        begin
          sleep message.seconds_in_future

          sub = subscriptions[message.subject] ||
            subscriptions[message.subject.split(".").first + ".*"]

          block = sub[:block]
          block.call(message.data) if block
          @next_message = message
          s = sub[:subscription]
          s.pending_queue.push(message) if s.pending_queue
        rescue => error
          puts error
        end
      end
    end
  end
end

class FakeNackClient < FakeNatsClient
  def publish(*)
    subscriptions.each do |_key, sub|
      s = sub[:subscription]
      s.pending_queue.push(NATS::Msg.new(:data => ::Protobuf::Nats::Messages::NACK, :subject => "BASE.#{@inbox}"))
    end
  end

  def subscribe(subject, args = {}, &block)
    s = super

    Thread.new do
      block.call(::Protobuf::Nats::Messages::NACK) if block
    end

    s
  end

  def next_message(_sub, _timeout)
    FakeNatsClient::Message.new("", ::Protobuf::Nats::Messages::NACK, 0)
  end
end
