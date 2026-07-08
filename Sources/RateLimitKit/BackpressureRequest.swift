import Foundation

/// A unit of outbound work the executor will rate-limit, coalesce, and
/// retry on its caller's behalf.
public struct BackpressureRequest: Identifiable, Sendable {
    public let id: UUID
    /// Requests that share a `coalescingKey` and are in flight at the same
    /// time are deduplicated to a single network call — e.g. two views
    /// both requesting the same "current user profile" refresh shouldn't
    /// generate two GETs.
    public let coalescingKey: String
    public let cost: Double
    public let payload: String

    public init(
        id: UUID = UUID(),
        coalescingKey: String,
        cost: Double = 1,
        payload: String
    ) {
        self.id = id
        self.coalescingKey = coalescingKey
        self.cost = cost
        self.payload = payload
    }
}

/// What the network actually did with a request.
public enum NetworkOutcome: Sendable, Equatable {
    case success(String)
    /// Server pushed back (HTTP 429). `retryAfter`, when present, is
    /// authoritative and should override the client's own backoff
    /// calculation — the server knows its own recovery time better than a
    /// generic exponential guess does.
    case rateLimited(retryAfter: TimeInterval?)
    case failure(String)
}

/// Result of running a request through the executor — what the caller
/// actually gets back. Not always terminal: `.queued` means the request is
/// sitting in the local bounded queue awaiting a future `drainQueued()`
/// call, which will itself resolve to one of the other three cases.
public enum ExecutionResult: Sendable, Equatable {
    case success(String)
    /// Accepted into the bounded local queue because tokens weren't
    /// available within the inline wait budget. Not a failure — the
    /// caller should expect this request to resolve later via
    /// `drainQueued()`.
    case queued
    /// The local bounded queue was full and this request was dropped
    /// before ever reaching the network. See `LocalRequestQueue`'s
    /// overflow policy for why this can happen and how to configure it.
    case droppedByOverflow
    /// Retries were exhausted (either backoff retries after 429s, or a
    /// drained queue item's single attempt) without success.
    case exhausted(lastError: String)
}
