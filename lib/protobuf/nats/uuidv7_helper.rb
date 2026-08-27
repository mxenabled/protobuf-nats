module Protobuf
  module Nats
    class UUIDv7Helper
      # Strict RFC 9562 UUIDv7 shape, matching what .generate produces. The
      # strictness matters to callers like the server's stale-request shedding:
      # treating a non-UUID token (e.g. from a foreign client) as a timestamp
      # would compute a garbage age.
      UUIDV7_REGEX = /\A\h{8}-\h{4}-7\h{3}-\h{4}-\h{12}\z/

      # Same shape without dashes. extract_timestamp has always accepted this
      # form, so validating with the dashed pattern alone would reject tokens
      # the method documents as supported.
      UUIDV7_COMPACT_REGEX = /\A\h{12}7\h{3}\h{4}\h{12}\z/

      # Generate a UUIDv7 string without a CSPRNG. Callers that only need a
      # 48-bit millisecond timestamp prefix (so #age_in_seconds can report a
      # value) plus enough randomness to stay unique among concurrent generators
      # don't need SecureRandom: its gen_random call dominated per-request CPU
      # and garbage (measured ~6.8us/op and 4 GC-triggering allocations). A
      # per-thread non-cryptographic Random halves both. The layout still matches
      # RFC 9562 UUIDv7 (version 7 + RFC 4122 variant bits).
      #
      # @return [String] a UUIDv7 string (e.g. "01234567-89ab-7def-8123-456789abcdef")
      def self.generate
        unix_ts_ms = ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond) & 0xffffffffffff
        rng = (::Thread.current[:pb_nats_uuid_rng] ||= ::Random.new)
        format(
          "%08x-%04x-%04x-%04x-%04x%08x",
          (unix_ts_ms >> 16) & 0xffffffff,   # 32 high bits of the ms timestamp
          unix_ts_ms & 0xffff,               # 16 low bits of the ms timestamp
          (0x7000 | rng.rand(0x1000)),       # version 7 + 12 random bits
          (0x8000 | rng.rand(0x4000)),       # RFC 4122 variant + 14 random bits
          rng.rand(0x10000),                 # 16 random bits
          rng.rand(0x100000000)              # 32 random bits
        )
      end

      # Extract the Unix timestamp (in seconds) from a UUIDv7 string
      # Returns nil if the UUID cannot be parsed
      #
      # Validates the whole token, not just its length. String#to_i(16) stops at
      # the first non-hex character and returns 0 rather than raising, so a
      # non-UUID reply token ("non-uuid-reply-token") used to parse as epoch 0
      # and report an age of ~56 years -- which #age_in_seconds then fed
      # straight into the client.unexpected_message gauge.
      #
      # @param uuid [String] A UUIDv7 string (e.g., "01234567-89ab-7def-0123-456789abcdef")
      # @return [Time, nil] The timestamp embedded in the UUID, or nil if parsing fails
      def self.extract_timestamp(uuid)
        return nil unless uuid.is_a?(String)
        return nil unless uuid.match?(UUIDV7_REGEX) || uuid.match?(UUIDV7_COMPACT_REGEX)

        # UUIDv7 format: first 48 bits (12 hex chars) are Unix timestamp in milliseconds
        # Remove dashes and extract the timestamp portion
        uuid_bytes = uuid.tr('-', '')

        timestamp_ms = uuid_bytes[0, 12].to_i(16)
        Time.at(timestamp_ms / 1000.0)
      rescue => e
        nil
      end

      # Calculate the age of a UUIDv7 in seconds
      # Returns nil if the UUID cannot be parsed
      #
      # @param uuid [String] A UUIDv7 string
      # @param current_time [Time] The time to compare against (defaults to Time.now)
      # @return [Float, nil] The age in seconds, or nil if parsing fails
      def self.age_in_seconds(uuid, current_time: Time.now)
        timestamp = extract_timestamp(uuid)
        return nil unless timestamp

        current_time - timestamp
      end


      # Age (integer ms) of a strictly-validated UUIDv7 token, or nil for a
      # non-UUIDv7 token. Allocation-light: runs per message on the server's
      # intake path.
      def self.age_ms(token)
        return nil unless token.is_a?(String) && token.match?(UUIDV7_REGEX)
        unix_ts_ms = (token[0, 8].to_i(16) << 16) | token[9, 4].to_i(16)
        ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond) - unix_ts_ms
      end
    end
  end
end
