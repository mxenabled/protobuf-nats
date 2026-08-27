require "spec_helper"

describe ::Protobuf::Nats::UUIDv7Helper do
  describe ".generate" do
    let(:uuid_format) { /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/ }

    it "produces a canonical UUID string" do
      expect(described_class.generate).to match(uuid_format)
    end

    it "sets the version nibble to 7" do
      # The 13th hex character (first nibble of the 3rd group) encodes the version.
      version_nibble = described_class.generate.delete('-')[12]
      expect(version_nibble).to eq("7")
    end

    it "sets the RFC 4122 variant bits" do
      # The 17th hex character (first nibble of the 4th group) encodes the variant;
      # for RFC 4122 it must be one of 8, 9, a, or b.
      variant_nibble = described_class.generate.delete('-')[16]
      expect(%w[8 9 a b]).to include(variant_nibble)
    end

    it "embeds the current time in the timestamp prefix" do
      uuid = described_class.generate
      expect(described_class.age_in_seconds(uuid)).to be_within(1.0).of(0.0)
    end

    it "round-trips through extract_timestamp" do
      before = Time.now
      uuid = described_class.generate
      after = Time.now

      timestamp = described_class.extract_timestamp(uuid)
      expect(timestamp).to be_a(Time)
      # Timestamp is truncated to milliseconds, so allow a small slack on the bounds.
      expect(timestamp.to_f).to be >= (before.to_f - 0.001)
      expect(timestamp.to_f).to be <= (after.to_f + 0.001)
    end

    it "generates unique values" do
      values = Array.new(10_000) { described_class.generate }
      expect(values.uniq.length).to eq(values.length)
    end

    it "is safe to call concurrently from multiple threads" do
      values = ::Concurrent::Array.new
      threads = Array.new(8) do
        Thread.new do
          1_000.times { values << described_class.generate }
        end
      end
      threads.each(&:join)

      expect(values.length).to eq(8_000)
      expect(values.uniq.length).to eq(values.length)
      values.each { |uuid| expect(uuid).to match(uuid_format) }
    end
  end

  describe ".extract_timestamp" do
    it "extracts the timestamp from a valid UUIDv7" do
      # Create a UUID with a known timestamp
      # 2024-01-01 00:00:00 UTC = 1704067200 seconds = 1704067200000 milliseconds = 0x18CF2B9C000
      known_time = Time.utc(2024, 1, 1, 0, 0, 0)
      timestamp_ms = (known_time.to_f * 1000).to_i
      hex_timestamp = timestamp_ms.to_s(16).rjust(12, '0')
      uuid = "#{hex_timestamp[0..7]}-#{hex_timestamp[8..11]}-7abc-9def-0123456789ab"

      timestamp = described_class.extract_timestamp(uuid)

      expect(timestamp).to be_a(Time)
      expect(timestamp.to_i).to eq(known_time.to_i)
    end

    it "returns nil for an invalid UUID" do
      expect(described_class.extract_timestamp("invalid")).to be_nil
      expect(described_class.extract_timestamp("")).to be_nil
      expect(described_class.extract_timestamp(nil)).to be_nil
    end

    it "returns nil for a short UUID string" do
      expect(described_class.extract_timestamp("123")).to be_nil
    end

    # String#to_i(16) stops at the first non-hex char and returns 0 instead of
    # raising, so these used to parse as epoch 0 -- an age of ~56 years, which
    # #age_in_seconds fed straight into the client.unexpected_message gauge.
    it "returns nil for a long non-hex token instead of parsing it as epoch 0" do
      expect(described_class.extract_timestamp("non-uuid-reply-token")).to be_nil
      expect(described_class.extract_timestamp("some.other.subject.token")).to be_nil
    end

    it "returns nil for a hex string that is not UUIDv7-shaped" do
      # Right length, right characters, wrong layout (no version 7 nibble).
      expect(described_class.extract_timestamp("0123456789abcdef0123456789abcdef")).to be_nil
    end

    it "handles UUIDs without dashes" do
      known_time = Time.utc(2024, 1, 1, 0, 0, 0)
      timestamp_ms = (known_time.to_f * 1000).to_i
      hex_timestamp = timestamp_ms.to_s(16).rjust(12, '0')
      uuid = "#{hex_timestamp}7abc9def0123456789ab"

      timestamp = described_class.extract_timestamp(uuid)

      expect(timestamp).to be_a(Time)
      expect(timestamp.to_i).to eq(known_time.to_i)
    end
  end

  describe ".age_in_seconds" do
    it "calculates the age of a UUIDv7" do
      # Create a UUIDv7 from 1 second ago
      one_second_ago = Time.now - 1
      timestamp_ms = (one_second_ago.to_f * 1000).to_i
      hex_timestamp = timestamp_ms.to_s(16).rjust(12, '0')
      uuid = "#{hex_timestamp[0..7]}-#{hex_timestamp[8..11]}-7abc-9def-0123456789ab"

      age = described_class.age_in_seconds(uuid)

      expect(age).to be_a(Float)
      expect(age).to be_within(0.1).of(1.0)
    end

    it "accepts a custom current_time parameter" do
      # Create a UUIDv7 from a known time
      uuid_time = Time.utc(2024, 1, 1, 0, 0, 0)
      timestamp_ms = (uuid_time.to_f * 1000).to_i
      hex_timestamp = timestamp_ms.to_s(16).rjust(12, '0')
      uuid = "#{hex_timestamp[0..7]}-#{hex_timestamp[8..11]}-7abc-9def-0123456789ab"

      # Calculate age relative to a time 10 seconds later
      later_time = uuid_time + 10
      age = described_class.age_in_seconds(uuid, current_time: later_time)

      expect(age).to be_within(0.001).of(10.0)
    end

    it "returns nil for invalid UUIDs" do
      expect(described_class.age_in_seconds("invalid")).to be_nil
      expect(described_class.age_in_seconds(nil)).to be_nil
      # Regression: a non-UUID reply token reported ~1.7e9 seconds (56 years),
      # skewing the client.unexpected_message metric.
      expect(described_class.age_in_seconds("non-uuid-reply-token")).to be_nil
    end
  end
end
