require "connection_pool"
require "protobuf/nats"
require "protobuf/rpc/connectors/base"
require "monitor"

module Protobuf
  module Nats
    class Client < ::Protobuf::Rpc::Connectors::Base

      CLIENT_MUTEX = ::Mutex.new

      # Structure to hold subscription and inbox to use within pool
      SubscriptionInbox = ::Struct.new(:subscription, :inbox) do
        def swap(sub_inbox)
          self.subscription = sub_inbox.subscription
          self.inbox = sub_inbox.inbox
        end
      end

      def self.subscription_pool
        @subscription_pool ||= ::ConnectionPool.new(:size => subscription_pool_size, :timeout => 0.1) do
          inbox = ::Protobuf::Nats.client_nats_connection.new_inbox

          SubscriptionInbox.new(::Protobuf::Nats.client_nats_connection.subscribe(inbox), inbox)
        end
      end

      def self.subscription_pool_size
        @subscription_pool_size ||= if ::ENV.key?("PB_NATS_CLIENT_SUBSCRIPTION_POOL_SIZE")
          ::ENV["PB_NATS_CLIENT_SUBSCRIPTION_POOL_SIZE"].to_i
        else
          0
        end
      end

      def initialize(options)
        # may need to override to setup connection at this stage ... may also do on load of class
        super

        # This will ensure the client is started.
        ::Protobuf::Nats.start_client_nats_connection
      end

      def new_subscription_inbox
        nats = ::Protobuf::Nats.client_nats_connection
        inbox = nats.new_inbox
        sub = if use_subscription_pooling?
                nats.subscribe(inbox)
              else
                nats.subscribe(inbox, :max => 2)
              end

        SubscriptionInbox.new(sub, inbox)
      end

      def with_subscription
        return_value = nil

        if use_subscription_pooling?
          self.class.subscription_pool.with do |sub_inbox|
            return_value = yield sub_inbox
          end
        else
          return_value = yield new_subscription_inbox
        end

        return_value
      end

      def close_connection
        # no-op (I think for now), the connection to server is persistent
      end

      def self.subscription_key_cache
        @subscription_key_cache ||= {}
      end

      def ack_timeout
        @ack_timeout ||= if ::ENV.key?("PB_NATS_CLIENT_ACK_TIMEOUT")
          ::ENV["PB_NATS_CLIENT_ACK_TIMEOUT"].to_i
        else
          5
        end
      end

      def nack_backoff_intervals
        @nack_backoff_intervals ||= if ::ENV.key?("PB_NATS_CLIENT_NACK_BACKOFF_INTERVALS")
          ::ENV["PB_NATS_CLIENT_NACK_BACKOFF_INTERVALS"].split(",").map(&:to_i)
        else
          [0, 1, 3, 5, 10]
        end
      end

      def nack_backoff_splay
        @nack_backoff_splay ||= if nack_backoff_splay_limit > 0
          rand(nack_backoff_splay_limit)
        else
          0
        end
      end

      def nack_backoff_splay_limit
        @nack_backoff_splay_limit ||= if ::ENV.key?("PB_NATS_CLIENT_NACK_BACKOFF_SPLAY_LIMIT")
          ::ENV["PB_NATS_CLIENT_NACK_BACKOFF_SPLAY_LIMIT"].to_i
        else
          10
        end
      end

      def reconnect_delay
        @reconnect_delay ||= if ::ENV.key?("PB_NATS_CLIENT_RECONNECT_DELAY")
          ::ENV["PB_NATS_CLIENT_RECONNECT_DELAY"].to_i
        else
          ack_timeout
        end
      end

      def response_timeout
        @response_timeout ||= if ::ENV.key?("PB_NATS_CLIENT_RESPONSE_TIMEOUT")
          ::ENV["PB_NATS_CLIENT_RESPONSE_TIMEOUT"].to_i
        else
          60
        end
      end

      def use_subscription_pooling?
        return @use_subscription_pooling unless @use_subscription_pooling.nil?
        @use_subscription_pooling = self.class.subscription_pool_size > 0
      end

      def send_request
        # This will ensure the client is started.
        ::Protobuf::Nats.start_client_nats_connection

        if use_subscription_pooling?
          available = self.class.subscription_pool.instance_variable_get("@available")
          ::ActiveSupport::Notifications.instrument "client.subscription_pool_available_size.protobuf-nats", available.length
        end

        ::ActiveSupport::Notifications.instrument "client.request_duration.protobuf-nats" do
          send_request_through_nats
        end
      end

      def send_request_through_nats
        retries ||= 3
        nack_retry ||= 0

        loop do
          setup_connection
          request_options = {:timeout => response_timeout, :ack_timeout => ack_timeout}
          @response_data = nats_request_with_two_responses(cached_subscription_key, @request_data, request_options)
          case @response_data
          when :ack_timeout
            ::ActiveSupport::Notifications.instrument "client.request_timeout.protobuf-nats"
            next if (retries -= 1) > 0
            raise ::Protobuf::Nats::Errors::RequestTimeout, formatted_service_and_method_name
          when :nack
            ::ActiveSupport::Notifications.instrument "client.request_nack.protobuf-nats"
            interval = nack_backoff_intervals[nack_retry]
            nack_retry += 1
            raise ::Protobuf::Nats::Errors::RequestTimeout, formatted_service_and_method_name if interval.nil?
            sleep((interval + nack_backoff_splay)/1000.0)
            next
          end

          break
        end

        parse_response
      rescue ::Protobuf::Nats::Errors::IOException => error
        ::Protobuf::Nats.log_error(error)

        delay = reconnect_delay
        logger.warn "An IOException was raised. We are going to sleep for #{delay} seconds."
        sleep delay

        retry if (retries -= 1) > 0
        raise
      end

      def cached_subscription_key
        klass = @options[:service]
        method_name = @options[:method]

        method_name_cache = self.class.subscription_key_cache[klass] ||= {}
        method_name_cache[method_name] ||= begin
          ::Protobuf::Nats.subscription_key(klass, method_name)
        end
      end

      def formatted_service_and_method_name
        klass = @options[:service]
        method_name = @options[:method]
        "#{klass}##{method_name}"
      end

      # The Java nats client offers better message queueing so we're going to use
      # that over locking ourselves. This split in code isn't great, but we can
      # refactor this later.
      if defined? JRUBY_VERSION

        # This is a request that expects two responses.
        # 1. An ACK from the server. We use a shorter timeout.
        # 2. A PB message from the server. We use a longer timoeut.
        def nats_request_with_two_responses(subject, data, opts)
          # Wait for the ACK from the server
          ack_timeout = opts[:ack_timeout] || 5
          # Wait for the protobuf response
          timeout = opts[:timeout] || 60

          nats = ::Protobuf::Nats.client_nats_connection

          # Publish to server
          with_subscription do |sub_inbox|
            begin
              completed_request = false

              if !sub_inbox.subscription.is_valid # replace the subscription if is has been pooled but is no longer valid (maybe a reconnect)
                nats.unsubscribe(sub_inbox.subscription)
                sub_inbox.swap(new_subscription_inbox) # this line replaces the sub_inbox in the connection pool if necessary
              end

              nats.publish(subject, data, sub_inbox.inbox)

              # Wait for reply
              first_message = nats.next_message(sub_inbox.subscription, ack_timeout)
              return :ack_timeout if first_message.nil?

              first_message_data = first_message.data
              return :nack if first_message_data == ::Protobuf::Nats::Messages::NACK

              second_message = nats.next_message(sub_inbox.subscription, timeout)
              second_message_data = second_message.nil? ? nil : second_message.data

              # Check messages
              response = case ::Protobuf::Nats::Messages::ACK
                         when first_message_data then second_message_data
                         when second_message_data then first_message_data
                         else return :ack_timeout
                         end

              fail(::Protobuf::Nats::Errors::ResponseTimeout, formatted_service_and_method_name) unless response

              completed_request = true
              response
            ensure
              if !completed_request
                nats.unsubscribe(sub_inbox.subscription)
                sub_inbox.swap(new_subscription_inbox) # this line replaces the sub_inbox in the connection pool if necessary
              end
            end
          end
        end

      elsif true

        def nats_request_with_two_responses(subject, data, opts)
          # Wait for the ACK from the server
          ack_timeout = opts[:ack_timeout] || 5
          # Wait for the protobuf response
          timeout = opts[:timeout] || 60

          nats = Protobuf::Nats.client_nats_connection

          # Cheap check first before synchronize
          unless @resp_sub_prefix
            CLIENT_MUTEX.synchronize do
              # TODO: This needs to be global, yo.
              start_request_muxer! unless @resp_sub_prefix
            end
          end

          # Publish message with the reply topic pointed at the response muxer.
          token = nats.new_inbox
          signal = @resp_sub.new_cond
          @resp_sub.synchronize do
            @resp_map[token][:signal] = signal
          end
          reply_to = "#{@resp_inbox_prefix}.#{token}"
          nats.publish(subject, data, reply_to)

          # Wait for reply

          # Receive the first message
          begin
            ::NATS::MonotonicTime::with_nats_timeout(ack_timeout) do
              @resp_sub.synchronize do
                signal.wait(ack_timeout)
              end
            end
          rescue ::NATS::Timeout => e
            return :ack_timeout
          end

          # Check for a NACK
          first_message = @resp_sub.synchronize { @resp_map[token][:response].shift }
          return :nack if first_message.data == ::Protobuf::Nats::Messages::NACK

          # Receive the second message
          begin
            ::NATS::MonotonicTime::with_nats_timeout(timeout) do
              @resp_sub.synchronize do
                signal.wait(timeout)
              end
            end
          rescue ::NATS::Timeout
            # ignore to raise a repsonse timeout below
          end

          # NOTE: This might be nil, so be careful checking the data value
          second_message_data = @resp_sub.synchronize { @resp_map[token][:response].shift }&.data

          # Check messages
          response = case ::Protobuf::Nats::Messages::ACK
                     when first_message.data then second_message_data
                     when second_message_data then first_message.data
                     else return :ack_timeout
                     end

          fail(::Protobuf::Nats::Errors::ResponseTimeout, formatted_service_and_method_name) unless response

          response
        ensure
          return if @resp_sub.nil?

          # Clean up
          @resp_sub.synchronize do
            @resp_map.delete(token)
          end
        end

        def start_request_muxer!
          nats = Protobuf::Nats.client_nats_connection
          @resp_inbox_prefix = nats.new_inbox
          @resp_map = Hash.new { |h,k| h[k] = { } }
          @resp_sub = nats.subscribe("#{@resp_inbox_prefix}.*")

          Thread.new do
            loop do
              msg = @resp_sub.pending_queue.pop
              next if msg.nil?
              @resp_sub.synchronize do
                # Decrease pending size since consumed already
                @resp_sub.pending_size -= msg.data.size
              end
              token = msg.subject.split('.').last

              @resp_sub.synchronize do
                # Reject if the token is missing from the request map
                next unless @resp_map.key?(token)

                future = @resp_map[token][:signal]
                @resp_map[token][:response] ||= []
                @resp_map[token][:response] << msg
                future.signal
              end
            end
          end
        end

      else

        fail "no longer using this impl for MRI"

        def nats_request_with_two_responses(subject, data, opts)
          nats = Protobuf::Nats.client_nats_connection
          inbox = nats.new_inbox
          lock = ::Monitor.new
          received = lock.new_cond
          messages = []
          first_message = nil
          second_message = nil
          response = nil

          sid = nats.subscribe(inbox, :max => 2) do |message, _, _|
            lock.synchronize do
              messages << message
              received.signal
            end
          end

          lock.synchronize do
            # Publish to server
            nats.publish(subject, data, inbox)

            # Wait for the ACK from the server
            ack_timeout = opts[:ack_timeout] || 5
            received.wait(ack_timeout) if messages.empty?
            first_message = messages.shift

            return :ack_timeout if first_message.nil?
            return :nack if first_message == ::Protobuf::Nats::Messages::NACK

            # Wait for the protobuf response
            timeout = opts[:timeout] || 60
            received.wait(timeout) if messages.empty?
            second_message = messages.shift
          end

          response = case ::Protobuf::Nats::Messages::ACK
                     when first_message then second_message
                     when second_message then first_message
                     else return :ack_timeout
                     end

          fail(::Protobuf::Nats::Errors::ResponseTimeout, formatted_service_and_method_name) unless response

          response
        ensure
          # Ensure we don't leave a subscription sitting around.
          nats.unsubscribe(sid) if response.nil?
        end

      end

    end
  end
end
