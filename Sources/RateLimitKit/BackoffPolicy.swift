import Foundation

/// Exponential backoff with jitter for retrying after a 429, honoring the
/// server's `Retry-After` when it provides one.
///
/// Design decision: server-provided `Retry-After` always wins over the
/// client's own exponential guess. A client backing off on a fixed
/// exponential schedule while ignoring a server's explicit "try again in
/// 30s" is exactly the kind of naive retry behavior that makes a 429 storm
/// worse instead of better — the whole point of this type existing.
public struct BackoffPolicy: Sendable {

    public let maxAttempts: Int
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let jitterSource: @Sendable () -> Double

    public init(
        maxAttempts: Int = 5,
        baseDelay: TimeInterval = 0.5,
        maxDelay: TimeInterval = 30.0,
        jitterSource: @escaping @Sendable () -> Double = { Double.random(in: 0.5...1.5) }
    ) {
        self.maxAttempts = Swift.max(1, maxAttempts)
        self.baseDelay = Swift.max(0, baseDelay)
        self.maxDelay = Swift.max(self.baseDelay, maxDelay)
        self.jitterSource = jitterSource
    }

    public func shouldRetry(attemptCount: Int) -> Bool {
        attemptCount < maxAttempts
    }

    /// Delay before the next attempt. If the server supplied a
    /// `Retry-After`, it's used directly (still capped at `maxDelay` so a
    /// misbehaving server can't stall a client indefinitely); otherwise
    /// falls back to jittered exponential backoff.
    public func delay(forAttemptCount attemptCount: Int, serverRetryAfter: TimeInterval? = nil) -> TimeInterval {
        if let serverRetryAfter, serverRetryAfter >= 0 {
            return Swift.min(serverRetryAfter, maxDelay)
        }
        let exponential = baseDelay * pow(2.0, Double(Swift.max(0, attemptCount)))
        let capped = Swift.min(exponential, maxDelay)
        return capped * jitterSource()
    }
}
