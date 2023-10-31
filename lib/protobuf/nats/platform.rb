module Protobuf
  module Nats
    def self.jruby?
      return false if jnats_disabled?

      defined? JRUBY_VERSION
    end

    def self.jnats_disabled?
      !!ENV["PB_NATS_DISABLE_JNATS"]
    end
  end
end

