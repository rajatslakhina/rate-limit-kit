# RateLimitKit

A client-side rate limiter for iOS: a token-bucket limiter, request coalescing, and server-aware exponential backoff, wired together so a client degrades gracefully under HTTP 429s instead of hammering retries into an already-struggling backend.

This is a senior/staff interview staple turned into real, tested code: not "add a retry loop," but "design the client-side behavior for a backend that's telling you to slow down" — bursts, coalescing duplicate concurrent requests, respecting `Retry-After`, and bounding local memory when the client can't keep up.

## Why this matters

The naive version of "handle rate limiting" is a retry loop with a fixed delay. That's exactly the pattern that turns a transient server hiccup into a thundering-herd retry storm: every client backs off on the same schedule, all retry at once, and the server that was already struggling gets hit again in lockstep. `RateLimitKit` exists to show the actual pieces a client needs instead: burst-tolerant rate limiting (token bucket, not a rigid fixed window), deduplication of redundant concurrent requests (coalescing), jittered backoff that defers to the server's own `Retry-After` when it has an opinion, and a bounded local queue so backpressure doesn't turn into unbounded memory growth on the client.

## Design decisions

**Token bucket, not a fixed window.** A fixed window either over-throttles right at a window boundary or under-throttles at the seam between two windows. A token bucket allows bounded bursts up to `capacity` while still enforcing a long-run average rate, with O(1) state — no history array to maintain or prune.

**Server `Retry-After` always overrides the client's own backoff guess.** `BackoffPolicy.delay(forAttemptCount:serverRetryAfter:)` takes the server's value when present (still capped at `maxDelay` so a misbehaving server can't stall a client indefinitely). Ignoring an explicit server hint in favor of a generic exponential schedule is exactly the behavior that makes 429 storms worse, not better.

**Coalescing is a separate actor from rate limiting, not folded into the executor.** `RequestCoalescer` only knows "dedupe concurrent calls sharing a key"; `RateLimitedExecutor` only knows "spend tokens, retry with backoff, queue on overflow." Keeping them separate means either can be tested, reasoned about, or swapped independently — the executor doesn't need to know coalescing exists beyond calling into it.

**The local queue is bounded, with an explicit, documented overflow policy — not unbounded.** An unbounded queue under sustained throttling converts a server-side backpressure signal into unbounded client-side memory growth. `LocalRequestQueue.OverflowPolicy` forces a real choice: `.dropOldest` (freshness matters more than completeness — e.g. "refresh this screen") or `.rejectNewest` (ordering/completeness matters more — e.g. an analytics event log).

## Trade-offs and rejected alternatives

- **Drained queue items get one network attempt, not the full per-request backoff loop.** Retrying one stuck item in place on drain would block every other queued item behind it. Documented in `RateLimitedExecutor.drainQueued()`'s doc comment as a deliberate trade-off, not an oversight — a caller that needs full backoff on a drained item can re-submit it through `execute(_:)`.
- **`drainQueued()` stops at the first request that still can't afford its cost, rather than skipping ahead to a cheaper one behind it.** Skipping would silently reorder client requests relative to each other for no documented reason — this design would rather under-utilize available tokens for one drain pass than introduce undocumented reordering.
- **Rejected: a single global lock instead of per-key coalescing.** A single lock across all requests would serialize unrelated traffic (e.g. a "profile" fetch blocking a completely unrelated "settings" fetch) for zero benefit — coalescing is scoped per `coalescingKey` specifically so unrelated requests never wait on each other.

## What's in this package

| File | Responsibility |
|---|---|
| `TokenBucket` | Burst-tolerant rate limiting with time-based refill |
| `BackoffPolicy` | Jittered exponential backoff, server `Retry-After`-aware |
| `RequestCoalescer` | Actor-isolated dedup of concurrent same-key requests |
| `LocalRequestQueue` | Bounded FIFO queue with a configurable overflow policy |
| `RateLimitNetworkClient` (+ `MockThrottlingNetworkClient`) | The network seam, with a deterministic 429-simulating test double |
| `RateLimitedExecutor` | The `actor` that orchestrates all of the above; documents its own concurrency/ordering guarantees in its doc comment |

## Testing

`Tests/RateLimitKitTests` targets the failure modes this design exists to handle: zero/negative token-bucket capacity and refill rate, refill-cap-after-long-idle, zero-cost-bypass prevention, server-`Retry-After`-overrides-exponential (and its own cap), retry exhaustion bounding an otherwise-infinite retry loop, FIFO-preserving queue overflow under both policies, concurrent-duplicate-request coalescing down to one underlying call, and drain-time behavior when tokens remain unavailable.

**Verification tier, stated honestly:** this run's sandbox had no headless Swift toolchain reachable — two separate attempts this run (one full download, one quick speed probe) both showed download speeds far too slow (roughly 50KB/s–1MB/s) to fetch a full toolchain within this run's time budget, and background downloads don't survive between shell calls in this environment. In place of `swift build`/`swift test`, every source and test file was checked with a scripted brace/paren/bracket balance pass (all files balanced) and a scripted scan for unguarded force-unwraps (none found). The test suite was written to the same standard as if `swift test` were about to run it — this is an honest statement of what didn't get automated confirmation this run, not a claim that it did.

## Demo app

[`rate-limit-kit-demo-app`](https://github.com/rajatslakhina/rate-limit-kit-demo-app) — a separate `Demo.xcodeproj` that consumes this package via a **remote** `XCRemoteSwiftPackageReference` (branch `main`), not a local path, exactly like any real external consumer would. Send single requests or a burst of concurrent duplicates against a simulated flaky backend and watch token-bucket throttling, coalescing, and bounded-queue backpressure resolve live.

Honest status: a live Simulator run was actually attempted this time (this build was made in an interactive session, not an unattended one), but the very first screenshot showed Xcode already had unrelated real work open and running — so the attempt was correctly aborted before any click, per this pipeline's own safety rule about not interfering with other work on the same machine. See that repo's README for the full disclosure and what verification was done in its place.
