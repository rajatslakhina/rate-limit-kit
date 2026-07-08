import Foundation

/// A classic token-bucket rate limiter: tokens refill continuously up to a
/// capacity, and each request consumes one or more tokens to proceed.
///
/// Design decision: token bucket (not a fixed sliding window) because it
/// allows short bursts up to `capacity` while still enforcing a long-run
/// average rate — a fixed window either over-throttles at window
/// boundaries or under-throttles right at the edge of two windows, and
/// token bucket avoids both failure modes with O(1) state (no history to
/// keep).
public struct TokenBucket: Sendable {

    public let capacity: Double
    public let refillRatePerSecond: Double

    private var tokens: Double
    private var lastRefill: Date
    private let clock: @Sendable () -> Date

    /// - Parameters:
    ///   - capacity: Maximum tokens the bucket can hold (also the max burst
    ///     size). Non-positive values are clamped to 1 — a bucket that can
    ///     never hold a token would make every request fail forever, which
    ///     is never the intended behavior for a misconfigured limiter.
    ///   - refillRatePerSecond: Tokens added per second. Clamped to a
    ///     non-negative value; zero is valid (a limiter that never refills,
    ///     e.g. for a one-shot burst allowance).
    public init(
        capacity: Double,
        refillRatePerSecond: Double,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.capacity = Swift.max(1, capacity)
        self.refillRatePerSecond = Swift.max(0, refillRatePerSecond)
        self.tokens = self.capacity
        self.lastRefill = clock()
        self.clock = clock
    }

    /// Attempts to consume `cost` tokens. Refills based on elapsed time
    /// first, then checks whether enough tokens are available. Returns
    /// whether the consumption succeeded; on failure, no tokens are
    /// deducted.
    ///
    /// `cost` is clamped to be at least 1 — a zero-cost request would let
    /// unlimited traffic through even at zero tokens, defeating the
    /// limiter's purpose.
    public mutating func tryConsume(cost: Double = 1) -> Bool {
        refill()
        let actualCost = Swift.max(1, cost)
        guard tokens >= actualCost else { return false }
        tokens -= actualCost
        return true
    }

    /// How many seconds until at least `cost` tokens will be available,
    /// assuming no other consumption happens in the meantime. Used by the
    /// executor to decide how long to hold a request in the local queue
    /// instead of busy-polling.
    public func timeUntilAvailable(cost: Double = 1) -> TimeInterval {
        let actualCost = Swift.max(1, cost)
        if tokens >= actualCost { return 0 }
        guard refillRatePerSecond > 0 else {
            // Never refills — the caller must not wait forever; surfacing
            // .infinity lets the executor decide to give up immediately
            // rather than queue indefinitely.
            return .infinity
        }
        let deficit = actualCost - tokens
        return deficit / refillRatePerSecond
    }

    private mutating func refill() {
        let now = clock()
        let elapsed = now.timeIntervalSince(lastRefill)
        guard elapsed > 0 else { return }
        // Capped at `capacity` — a bucket left untouched for a long time
        // must not accumulate unbounded tokens, or a long-idle client would
        // get an unbounded burst allowance on its next request.
        tokens = Swift.min(capacity, tokens + elapsed * refillRatePerSecond)
        lastRefill = now
    }
}
