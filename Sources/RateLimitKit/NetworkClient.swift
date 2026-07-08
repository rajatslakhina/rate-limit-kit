import Foundation

/// Network boundary the executor talks to. Minimal and protocol-based so
/// tests can inject deterministic 429-throttling behavior without any real
/// networking.
public protocol RateLimitNetworkClient: Sendable {
    func send(_ request: BackpressureRequest) async -> NetworkOutcome
}

/// A network client that deliberately throttles — returns 429
/// (`.rateLimited`) for a configurable number of calls per coalescing key
/// before succeeding, optionally with a server-supplied `Retry-After`. Lets
/// tests exercise the backoff and coalescing paths deterministically.
public final class MockThrottlingNetworkClient: RateLimitNetworkClient, @unchecked Sendable {

    public struct Configuration: Sendable {
        /// How many times a given key must be throttled before the mock
        /// starts returning success.
        public var throttleCountPerKey: Int
        public var retryAfter: TimeInterval?
        public var failAfterThrottling: Bool

        public init(
            throttleCountPerKey: Int = 0,
            retryAfter: TimeInterval? = nil,
            failAfterThrottling: Bool = false
        ) {
            self.throttleCountPerKey = Swift.max(0, throttleCountPerKey)
            self.retryAfter = retryAfter
            self.failAfterThrottling = failAfterThrottling
        }
    }

    private let configuration: Configuration
    private let lock = NSLock()
    private var callCountsByKey: [String: Int] = [:]
    /// Every request actually sent to the network, in call order — lets
    /// tests assert exactly how many real network calls were made (e.g. to
    /// prove coalescing collapsed N callers into 1 call).
    public private(set) var sentRequestIDs: [UUID] = []

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func send(_ request: BackpressureRequest) async -> NetworkOutcome {
        lock.lock()
        sentRequestIDs.append(request.id)
        let count = callCountsByKey[request.coalescingKey, default: 0]
        callCountsByKey[request.coalescingKey] = count + 1
        lock.unlock()

        if count < configuration.throttleCountPerKey {
            if configuration.failAfterThrottling {
                return .failure("simulated failure after throttle window")
            }
            return .rateLimited(retryAfter: configuration.retryAfter)
        }
        return .success("ok:\(request.payload)")
    }
}
