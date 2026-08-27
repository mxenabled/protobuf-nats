require 'simplecov'
SimpleCov.start

# Keep the response muxer deterministic in tests: a single dispatcher thread.
# (In production this auto-scales on JRuby; see ResponseMuxer#dispatcher_count.)
ENV["PB_NATS_RESPONSE_MUXER_DISPATCHERS"] ||= "1"

require "bundler/setup"
require "socket"
require "timeout"
require "protobuf/nats"
require "fake_nats_client"
require "pry"

# Integration specs (spec/integration/) exercise a real NATS server. They run
# automatically when one is reachable (a local `nats-server`, or the CI service
# container) and are excluded otherwise, so the unit suite never needs NATS.
PB_NATS_INTEGRATION_HOST = ENV.fetch("PB_NATS_INTEGRATION_HOST", "127.0.0.1")
PB_NATS_INTEGRATION_PORT = Integer(ENV.fetch("PB_NATS_INTEGRATION_PORT", "4222"))
PB_NATS_INTEGRATION_AVAILABLE = begin
  # Bounded connect so an unreachable (packet-dropping) host can't stall
  # every test run for the OS connect timeout.
  ::Socket.tcp(PB_NATS_INTEGRATION_HOST, PB_NATS_INTEGRATION_PORT, :connect_timeout => 1).close
  true
rescue ::StandardError
  false
end

# The cluster failover spec (spec/integration/failover_spec.rb) spawns its own
# two-node cluster, so it needs the nats-server binary itself (not just a
# reachable server).
PB_NATS_SERVER_BINARY_AVAILABLE = begin
  system("nats-server", "--version", :out => ::File::NULL, :err => ::File::NULL) ? true : false
rescue ::StandardError
  false
end

# Turn off protobuf logging.
::Protobuf::Logging.logger = ::Logger.new(nil)

# Deterministic polling helper for concurrency specs: wait for a condition
# instead of sleeping a fixed amount and hoping. Fails fast on timeout.
module WaitHelpers
  def wait_until(timeout: 2, interval: 0.005)
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout
    until yield
      if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline
        raise "wait_until timed out after #{timeout}s"
      end
      sleep interval
    end
  end
end

RSpec.configure do |config|
  config.include WaitHelpers

  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"
  config.order = :random
  config.color = true

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.filter_run_excluding(:integration => true) unless PB_NATS_INTEGRATION_AVAILABLE
  config.filter_run_excluding(:integration_cluster => true) unless PB_NATS_SERVER_BINARY_AVAILABLE

  config.before(:each) do |example|
    # Integration examples open a real connection; everything else must never.
    unless example.metadata[:integration] || example.metadata[:integration_cluster]
      allow(::Protobuf::Nats).to receive(:start_client_nats_connection)
    end

    ::Protobuf::Nats::Client::RESPONSE_MUXER.restart
  end
end
