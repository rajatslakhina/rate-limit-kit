import Foundation

/// A bounded FIFO queue for requests that are waiting on the token bucket.
///
/// Design decision: bounded, not unbounded. An unbounded local queue under
/// sustained rate-limiting turns a server-side backpressure signal into
/// unbounded client-side memory growth — the queue would keep accepting
/// work the client can provably never keep up with. Bounding it forces an
/// explicit, documented choice about what happens when the queue is full.
public actor LocalRequestQueue {

    /// What happens when `enqueue` is called on a full queue.
    public enum OverflowPolicy: Sendable {
        /// Drop the oldest queued request to make room for the new one.
        /// Appropriate when only the *latest* state matters (e.g. a
        /// "refresh this screen" request) — an old queued request is
        /// probably stale anyway.
        case dropOldest
        /// Reject the new request outright, leaving the queue as-is.
        /// Appropriate when ordering/completeness matters more than
        /// freshness (e.g. a queue of analytics events where dropping an
        /// old one silently would corrupt an ordered log).
        case rejectNewest
    }

    private var storage: [BackpressureRequest] = []
    private let capacity: Int
    private let overflowPolicy: OverflowPolicy

    public init(capacity: Int = 50, overflowPolicy: OverflowPolicy = .dropOldest) {
        // A queue with zero or negative capacity would reject every single
        // enqueue, silently turning "rate limited" into "always dropped" —
        // clamp to a sane floor instead.
        self.capacity = Swift.max(1, capacity)
        self.overflowPolicy = overflowPolicy
    }

    /// Attempts to enqueue. Returns the request that was dropped as a
    /// result (either `request` itself under `.rejectNewest`, or the
    /// previous oldest entry under `.dropOldest`), or `nil` if nothing was
    /// dropped.
    @discardableResult
    public func enqueue(_ request: BackpressureRequest) -> BackpressureRequest? {
        guard storage.count >= capacity else {
            storage.append(request)
            return nil
        }

        switch overflowPolicy {
        case .rejectNewest:
            return request
        case .dropOldest:
            let dropped = storage.removeFirst()
            storage.append(request)
            return dropped
        }
    }

    public func dequeue() -> BackpressureRequest? {
        guard !storage.isEmpty else { return nil }
        return storage.removeFirst()
    }

    /// Looks at the head of the queue without removing it — lets a drain
    /// loop check "would this request's cost fit in the bucket right now?"
    /// before committing to a dequeue, so a still-blocked request stays at
    /// the front (FIFO preserved) instead of being popped and re-pushed to
    /// the back out of order.
    public func peek() -> BackpressureRequest? {
        storage.first
    }

    public func all() -> [BackpressureRequest] {
        storage
    }

    public var count: Int {
        storage.count
    }
}
