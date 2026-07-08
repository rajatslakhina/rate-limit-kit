import XCTest
@testable import RateLimitKit

final class BackoffPolicyTests: XCTestCase {

    func testZeroAndNegativeMaxAttemptsClampToOne() {
        XCTAssertEqual(BackoffPolicy(maxAttempts: 0).maxAttempts, 1)
        XCTAssertEqual(BackoffPolicy(maxAttempts: -4).maxAttempts, 1)
    }

    func testMaxDelayBelowBaseDelayCorrectedUpward() {
        let policy = BackoffPolicy(baseDelay: 5, maxDelay: 1)
        XCTAssertEqual(policy.maxDelay, 5)
    }

    func testShouldRetryRespectsMaxAttempts() {
        let policy = BackoffPolicy(maxAttempts: 3)
        XCTAssertTrue(policy.shouldRetry(attemptCount: 0))
        XCTAssertTrue(policy.shouldRetry(attemptCount: 2))
        XCTAssertFalse(policy.shouldRetry(attemptCount: 3))
    }

    func testServerRetryAfterOverridesExponentialCalculation() {
        let policy = BackoffPolicy(baseDelay: 1, maxDelay: 100, jitterSource: { 1.0 })
        // Exponential for attempt 5 would be 32s, but the server explicitly
        // said 3s — server wins.
        XCTAssertEqual(policy.delay(forAttemptCount: 5, serverRetryAfter: 3), 3)
    }

    func testServerRetryAfterStillCappedAtMaxDelay() {
        let policy = BackoffPolicy(baseDelay: 1, maxDelay: 10, jitterSource: { 1.0 })
        // A misbehaving server asking for a 1-hour retry must not stall the
        // client indefinitely beyond the configured ceiling.
        XCTAssertEqual(policy.delay(forAttemptCount: 1, serverRetryAfter: 3600), 10)
    }

    func testNegativeServerRetryAfterIsIgnored() {
        let policy = BackoffPolicy(baseDelay: 1, maxDelay: 100, jitterSource: { 1.0 })
        // A negative Retry-After is nonsensical; fall back to exponential
        // rather than propagate a negative delay.
        XCTAssertEqual(policy.delay(forAttemptCount: 0, serverRetryAfter: -5), 1)
    }

    func testExponentialGrowthWithoutServerHint() {
        let policy = BackoffPolicy(maxAttempts: 10, baseDelay: 1, maxDelay: 100, jitterSource: { 1.0 })
        XCTAssertEqual(policy.delay(forAttemptCount: 0), 1)
        XCTAssertEqual(policy.delay(forAttemptCount: 1), 2)
        XCTAssertEqual(policy.delay(forAttemptCount: 2), 4)
    }

    func testExponentialGrowthCapsAtMaxDelay() {
        let policy = BackoffPolicy(maxAttempts: 10, baseDelay: 1, maxDelay: 5, jitterSource: { 1.0 })
        XCTAssertEqual(policy.delay(forAttemptCount: 10), 5)
    }
}
