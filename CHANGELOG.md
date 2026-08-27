## Changelog

### 0.13.3.pre1
Correctness fixes for concurrency bugs found while reviewing the 0.13.1/0.13.2 changes. Every fix ships with a spec verified to fail against the previous code. No API or configuration changes.

#### Byte accounting
- Fixed permanent upward drift in the `ByteBoundedQueue` byte counter (new in 0.13.2). Bytes were counted *after* the enqueue, so a consumer could pop an item and subtract its bytes first; `pop`'s clamp at zero swallowed that subtraction, and the producer's increment then applied to an item that was already gone. The counter only ratcheted up, so a long-running server eventually reached the 128 MiB ceiling and dropped **every** request while still looking healthy. The server pops the shared queue from `processor_count` handler threads on JRuby, so the race was live on every message. Bytes are now counted before the enqueue and rolled back if it does not happen.

#### Shutdown
- Work accepted just as shutdown begins is no longer stranded. `ThreadPool#push` checks the shutdown flag and then enqueues, so `shutdown` could slip its poison pills between those two steps; workers took a pill and exited, leaving an already-ACKed request to hang until the client's response timeout (60s default). Workers now drain work queued behind their pill, and `wait_for_termination` drains once more after the last worker exits. Admission and shutdown are still not atomic (`#push` is lock-free by design), but nothing enqueued before the pool reports termination is dropped.
- Removed the `Timeout.timeout(10)` wrapper around `SuperSubscriptionManager#shutdown` in `Server#run`. 0.13.1 removed `Timeout` from the manager because its async `Thread#raise`, fired while a thread holds the `SizedQueue` mutex, makes JRuby unwind through the held mutex; the wrapper reintroduced that hazard one frame up. It could genuinely fire: `#shutdown` is not bounded by 10s (one 1s push deadline per handler, then a 5s join, then 1s kill-joins). `#shutdown` already self-bounds, so the wrapper is gone along with the now-dead `require "timeout"`.

#### Self-healing
- A response-muxer dispatcher that crashes now tears down only the subscription it actually died on. Dispatchers that crash together wake on staggered backoffs (1s, then 4s), so a late one destroyed the subscription an earlier one had just rebuilt and, via `fail_inflight_requests`, cancelled every request already waiting on it.

#### Observability
- `UUIDv7Helper.extract_timestamp` validates the whole token instead of just its length. `String#to_i(16)` stops at the first non-hex character and returns 0 rather than raising, so a foreign reply token parsed as epoch 0 and reported a ~56-year age into the `client.unexpected_message` gauge. Both the dashed and compact (dash-free) UUIDv7 forms are still accepted.

### 0.13.2
Bounds the RPC transport's in-memory buffering to prevent the JVM-heap OOM introduced by the JNats → nats-pure migration. Both the client response muxer and the server intake queue are now capped by message count **and** total bytes, dropping (with client retry) rather than buffering unbounded protobuf payloads on the heap.

#### Client: response-muxer heap bound
- The shared response "firehose" is bounded by both a message count (`PB_NATS_RESPONSE_MUXER_QUEUE_SIZE`, default `1024`) and a byte ceiling (`PB_NATS_RESPONSE_MUXER_QUEUE_BYTES`, default 64 MiB); nats-pure drops (`SlowConsumer`) on whichever trips first and the RPC retries. Previously only nats-pure's 65,536-message count applied with the byte limit disabled, so a burst of large responses could hold gigabytes of Ruby objects on the JVM heap.
- The muxer now decrements the subscription's `pending_size` after each pop, keeping a *finite* byte limit accurate — instead of disabling it as before. If a subscription can't support that accounting (no `#synchronize`), `start` raises `IncompatibleSubscription` (a tripwire for a breaking nats-pure change) rather than silently degrading.
- New gauges: `response_muxer.pending_queue_size` and `response_muxer.pending_queue_peak` (high-water mark between the ~60s samples).

#### Server: intake heap bound
- The shared intake queue is now bounded by bytes as well as count: new `PB_NATS_SERVER_INTAKE_QUEUE_BYTES` (default 128 MiB), enforced by a `ByteBoundedQueue` with a shared byte counter. A request that would exceed the ceiling is dropped (the client retries) and emits `server.intake_bytes_dropped`; new gauge `server.pending_intake_queue_bytes`. nats-pure's per-subscription byte limit stays disabled — the shared queue counter owns byte bounding, since many subscriptions funnel into one queue.
- Fixed a slow leak of orphaned `@overdue_flagged` entries caused by a handler-completion race; the periodic monitor now reaps them.

### 0.13.1
Fixes regressions from the JNats → nats-pure migration (0.13.0) plus a full reliability, performance, and security hardening pass. Highlights: the client reconnects and retries correctly through dropped connections, failing nodes, and terminal closes; the server survives overload and connection loss instead of going silently deaf; TLS actually verifies the server certificate.

#### Client: reconnect & retry
- Restored dropped-connection retries (the retry rescue matched an error nothing raised). The client now retries the transport errors nats-pure actually raises: `EOFError`, `IOError`, `Errno::ECONNRESET`/`EPIPE`/`ECONNREFUSED`/`ECONNABORTED`/`ETIMEDOUT`/`EHOSTUNREACH`/`ENETUNREACH`, `NATS::IO::ConnectionClosedError`, and Java `IOException` on JRuby.
- A terminally closed connection self-heals: `on_close` drops the cached connection, the next request (or in-flight retry) rebuilds it, and the response muxer detects the swap and re-subscribes on the live connection. Previously every RPC timed out until the process restarted.
- A muxer restart wakes in-flight waiters immediately instead of leaving them to burn the full timeout on responses that can never arrive.
- Retries are bounded and jittered (`PB_NATS_CLIENT_MAX_RETRIES`, `PB_NATS_CLIENT_RECONNECT_DELAY_SPLAY_LIMIT`), and the final failed attempt raises immediately instead of sleeping first.
- The muxer token TTL stretches with a response timeout configured beyond 600s, so long waits aren't cleaned up mid-request.

#### Server: reliability
- Subscriptions no longer go permanently deaf under cumulative traffic: the byte-based slow-consumer limit (which nats-pure never decrements on our consumption path) is disabled on both client and server subscriptions; the accurate message-count limit still applies.
- Tuning `PB_NATS_SERVER_INTAKE_QUEUE_SIZE` down is safe: the slow-consumer limit is kept aligned with the queue capacity, so overload drops promptly instead of blocking nats-pure's read thread (which froze PING/PONG and every subject).
- A terminally closed connection stops the server (logs + `server.connection_closed`) so a supervisor restarts it, instead of idling forever subscribed to nothing.
- Failed handlers publish an RPC error response so the client fails fast instead of hanging until its response timeout; a failed success-publish no longer emits a duplicate error response; client-facing error messages are generic (details stay in server logs).
- Pause/resume no longer leaks subscriptions; the thread-pool counter no longer goes negative at shutdown; dispatch/intake threads park instead of busy-spinning on a closed queue; self-healing always respawns a replacement dispatcher, with thread-safe backoff that decays when healthy.
- Opt-in stale-request shedding (`PB_NATS_SERVER_STALE_REQUEST_MS`) and opt-in overdue-handler reclaim (`PB_NATS_SERVER_RECLAIM_OVERDUE_HANDLERS`). Handlers are still never aborted by default, and shutdown drains in-flight handlers before closing.
- Lifecycle callbacks (client and server) register before `connect`, so handshake-window events are observed; a failed handshake closes the half-open client instead of leaking its reader/flusher threads.

#### Performance
- Server intake fans out across `PB_NATS_SERVER_SUBSCRIPTION_HANDLERS` threads (default `processor_count` on JRuby, 1 on CRuby): ~8.5× intake throughput, head-of-line stalls ~505ms → ~0.4ms (`bench/server_intake_bench.rb`).
- Muxer dispatch dropped its per-message lock (~2.7× faster on JRuby, `bench/muxer_resilience_bench.rb`) and extracts reply tokens without `split` allocations.
- `ThreadPool#push` no longer supervises the worker pool per request (the server's 1s `replenish` tick is the sole respawn path), and `ResponseMuxer#start`'s once-per-RPC check is a lock-free atomic read.
- User error callbacks run on a bounded executor off nats-pure's read thread; drops are counted (`error_callback_drop_count`) and instrumented.

#### Failover & configuration
- New yaml keys `reconnect_time_wait`, `ping_interval`, and `max_outstanding_pings` are forwarded to nats-pure for faster dead-node detection (defaults unchanged); `max_reconnect_attempts: -1` reconnects forever.
- Numeric env vars parse strictly: malformed values (`"5s"`, `"fast,slow"`) log and fall back to defaults instead of silently becoming `0`; `PB_NATS_SERVER_MAX_QUEUE_SIZE` defaults to the resolved thread count.
- `connection_options` forwards only nats-pure-recognized keys (the dead JNats-era `:disable_reconnect_buffer` option is gone), and connections are named (`PB_NATS_CONNECTION_NAME` > yaml `connection_name` > hostname) for NATS monitoring.
- A yaml config that is empty or has no section for the current environment falls back to defaults instead of crashing at boot.
- New in-flight handler observability: `server.inflight_count`, `server.inflight_oldest_age_ms`, `server.overdue_handler_count`, `server.pending_intake_queue_size`, `server.slow_handler` (opt-in), `server.thread_pool_saturated`; server durations use a monotonic clock.

#### Security
- TLS now verifies the NATS server certificate chain (`VERIFY_PEER`, trusting `tls_ca_cert` or the system store). **Breaking for misconfigured deployments** whose certificates don't chain to the trusted CA — they previously connected unverified.
- TLS negotiates 1.2–1.3 (replacing the deprecated 1.2 hard pin); OpenSSL builds without TLS 1.3 degrade to a 1.2 ceiling instead of raising.
- YAML config uses `safe_load` (aliases allowed, arbitrary object deserialization rejected). TLS client keys may be any key type (`OpenSSL::PKey.read`).
- Known gap: TLS hostname (SAN/CN) verification remains off — it needs per-connection plumbing in nats-pure; tracked separately.

#### Testing, CI, dependencies
- Real-NATS integration specs (auto-detected on `localhost:4222`): full RPC round trip, concurrency with real NACK backpressure, terminal-close self-heal, and a two-node cluster failover spec that spawns its own cluster and kills the node the client is connected to (gated on the `nats-server` binary). GitHub Actions runs the suite on CRuby 3.1/3.4 and JRuby 9.4/10.0.
- nats-pure pinned to `>= 2.5, < 3`: the gem relies on nats-pure internals (pending-queue swap, slow-consumer semantics, subscription replay, infinite-reconnect flag) verified against 2.5.
- Removed the unused `connection_pool` dependency and the dead client subscription-pool code; `require "timeout"` is explicit where used.
- Soak-tested with chaos runs (nats-server killed twice mid-run): 99.4% success on CRuby 3.4, 100% on JRuby 10.0.

### 0.13.0
This is a large overhaul of the client and server internals.

#### Highlights
- Removed JNats / the forked java-nats client. `nats-pure` is now used on both JRuby and CRuby (it is fast enough for parallel work), so there is a single NATS client implementation (`NATS::IO::Client`).
- Added the `ResponseMuxer`: a single wildcard subscription multiplexes all client responses (similar to the Golang client) instead of one subscription per request. This replaces the previous per-request subscribe/unsubscribe cycle and significantly reduces subscription churn.
- Added the `SuperSubscriptionManager` on the server for managing RPC endpoint subscriptions.
- Switched to `concurrent-ruby` primitives for lock-free response delivery (`Concurrent::Map`) and performance gains.
- Switched request tokens to UUIDv7 (via the `uuid7` gem, see `UUIDv7Helper`) for time-ordered, more robust request correlation.
- Added instrumentation/logging when encountering unexpected messages.
- More robust periodic cleanup, locking, restart handling, and error handling in the client and server.

#### New environment variables
- `PB_NATS_RESPONSE_MUXER_DISPATCHERS` - Number of dispatcher threads draining the shared response subscription. Defaults to `Concurrent.processor_count` on JRuby (true parallelism) and `1` on CRuby (the GVL makes extra dispatchers pointless). Minimum of 1.

#### Dependencies / requirements
- Now requires Ruby `>= 3.1.0`.
- Bumped `nats-pure` to `~> 2` (from `~> 0.3`).
- Bumped `activesupport` to `>= 6.1` (from `>= 3.2`).
- Added `concurrent-ruby` (`~> 1.3.6`, pinned so `logger` is included) and `uuid7` runtime dependencies.
- Pinned `i18n` to `< 1.15.0` in the Gemfile (workaround for ruby-i18n/i18n#735).
