import Foundation

/// Deduplicates concurrent in-flight requests that share a coalescing key
/// down to a single network call, fanning the one result back out to every
/// caller waiting on it.
///
/// Design decision: this is an `actor`, so the "does a task for this key
/// already exist?" check-and-create is atomic — a plain class with a
/// dictionary would have a race where two concurrent callers both see "no
/// existing task" and both start a network call, defeating the whole
/// point of coalescing.
public actor RequestCoalescer {

    private var inFlight: [String: Task<NetworkOutcome, Never>] = [:]

    public init() {}

    public func execute(
        key: String,
        operation: @escaping @Sendable () async -> NetworkOutcome
    ) async -> NetworkOutcome {
        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task { await operation() }
        inFlight[key] = task
        let result = await task.value
        // `Task` isn't `Equatable`, so we can't compare "is this still the
        // task I started" directly. That's fine here: `inFlight[key]` can
        // only ever be overwritten by a *later* call to `execute(key:)`
        // for the same key, which only happens after the current entry has
        // already been cleared (this actor's isolation serializes that),
        // so an unconditional clear can never stomp on a newer in-flight
        // task.
        inFlight[key] = nil
        return result
    }

    /// Number of distinct keys currently coalescing an in-flight call —
    /// exposed for observability/tests, not used by the executor itself.
    public var activeKeyCount: Int {
        inFlight.count
    }
}
