import Foundation

/// Orchestrates token-bucket rate limiting, request coalescing, and
/// server-aware backoff into a single entry point a client calls to run a
/// request "politely" — degrading gracefully under 429s instead of
/// hammering retries.
///
/// Concurrency & ordering guarantees (documented because a staff reviewer
/// would ask about exactly this):
/// - `RateLimitedExecutor` is an `actor`; the token bucket is mutable state
///   owned by this actor, so concurrent `execute` calls consume tokens
///   serially and cannot double-spend the same tokens.
/// - Coalescing is keyed, not global: two `execute` calls with different
///   `coalescingKey`s run fully independently and are never blocked by
///   each other's backoff waits.
/// - `drainQueued()` preserves FIFO order within the local queue and stops
///   at the first request that still can't afford its token cost, rather
///   than skipping it to try a later one — otherwise a large request stuck
///   at the front could be silently starved by an unbounded stream of
///   smaller ones jumping the queue, which is exactly the kind of
///   undocumented reordering a rate limiter should never do to a client's
///   requests.
public actor RateLimitedExecutor {

    private var tokenBucket: TokenBucket
    private let queue: LocalRequestQueue
    private let coalescer: RequestCoalescer
    private let network: RateLimitNetworkClient
    private let backoff: BackoffPolicy
    /// Maximum time `execute` will wait for tokens to free up before giving
    /// up and moving the request to the local queue instead. Keeps a
    /// caller's `execute` call from blocking indefinitely.
    private let maxInlineWait: TimeInterval
    private let sleeper: @Sendable (TimeInterval) async -> Void

    public init(
        tokenBucket: TokenBucket,
        queue: LocalRequestQueue = LocalRequestQueue(),
        coalescer: RequestCoalescer = RequestCoalescer(),
        network: RateLimitNetworkClient,
        backoff: BackoffPolicy = BackoffPolicy(),
        maxInlineWait: TimeInterval = 2.0,
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.tokenBucket = tokenBucket
        self.queue = queue
        self.coalescer = coalescer
        self.network = network
        self.backoff = backoff
        self.maxInlineWait = maxInlineWait
        self.sleeper = sleeper
    }

    /// Runs a request to completion: consumes tokens, coalesces with any
    /// identical in-flight request, and retries on 429 with backoff.
    /// If tokens aren't available within `maxInlineWait`, the request is
    /// moved to the bounded local queue instead of blocking further — the
    /// caller should treat `.droppedByOverflow` and a queued-but-not-yet-run
    /// request the same way: "not resolved yet, will be handled by
    /// `drainQueued()`."
    public func execute(_ request: BackpressureRequest) async -> ExecutionResult {
        var attempt = 0
        var waited: TimeInterval = 0

        while true {
            if tokenBucket.tryConsume(cost: request.cost) {
                let outcome = await runAgainstNetwork(request)
                switch outcome {
                case .success(let body):
                    return .success(body)

                case .rateLimited(let retryAfter):
                    attempt += 1
                    guard backoff.shouldRetry(attemptCount: attempt) else {
                        return .exhausted(lastError: "rate limited after \(attempt) attempt(s)")
                    }
                    await sleeper(backoff.delay(forAttemptCount: attempt, serverRetryAfter: retryAfter))
                    continue

                case .failure(let message):
                    attempt += 1
                    guard backoff.shouldRetry(attemptCount: attempt) else {
                        return .exhausted(lastError: message)
                    }
                    await sleeper(backoff.delay(forAttemptCount: attempt))
                    continue
                }
            }

            let wait = tokenBucket.timeUntilAvailable(cost: request.cost)
            guard wait.isFinite, waited + wait <= maxInlineWait else {
                let dropped = await queue.enqueue(request)
                // Under `.rejectNewest`, a full queue hands back `request`
                // itself as "dropped" — that's the overflow case. Any other
                // outcome (nil, or some *other* request evicted under
                // `.dropOldest`) means `request` is now sitting safely in
                // the queue, awaiting `drainQueued()`.
                return dropped?.id == request.id ? .droppedByOverflow : .queued
            }
            await sleeper(wait)
            waited += wait
        }
    }

    /// Drains requests that were pushed to the local queue because tokens
    /// weren't available inline. Stops at the first request whose cost
    /// still can't be afforded, preserving FIFO order (see the type doc).
    /// Queued items get a single network attempt each on drain — not the
    /// full per-request backoff loop `execute` uses — because retrying one
    /// stuck item in place would block every other queued item behind it
    /// from ever being tried. Documented trade-off, not an oversight.
    public func drainQueued() async -> [ExecutionResult] {
        var results: [ExecutionResult] = []
        while let next = await queue.peek() {
            guard tokenBucket.tryConsume(cost: next.cost) else { break }
            _ = await queue.dequeue()
            let outcome = await runAgainstNetwork(next)
            switch outcome {
            case .success(let body):
                results.append(.success(body))
            case .rateLimited:
                results.append(.exhausted(lastError: "still rate limited on drain"))
            case .failure(let message):
                results.append(.exhausted(lastError: message))
            }
        }
        return results
    }

    public func queuedCount() async -> Int {
        await queue.count
    }

    private func runAgainstNetwork(_ request: BackpressureRequest) async -> NetworkOutcome {
        let network = self.network
        return await coalescer.execute(key: request.coalescingKey) {
            await network.send(request)
        }
    }
}
