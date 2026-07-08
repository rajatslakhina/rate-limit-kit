import XCTest
@testable import RateLimitKit

final class TokenBucketTests: XCTestCase {

    func testZeroCapacityClampsToOne() {
        let bucket = TokenBucket(capacity: 0, refillRatePerSecond: 1)
        XCTAssertEqual(bucket.capacity, 1)
    }

    func testNegativeCapacityClampsToOne() {
        let bucket = TokenBucket(capacity: -10, refillRatePerSecond: 1)
        XCTAssertEqual(bucket.capacity, 1)
    }

    func testNegativeRefillRateClampsToZero() {
        let bucket = TokenBucket(capacity: 5, refillRatePerSecond: -3)
        XCTAssertEqual(bucket.refillRatePerSecond, 0)
    }

    func testStartsFull() {
        var bucket = TokenBucket(capacity: 3, refillRatePerSecond: 1)
        XCTAssertTrue(bucket.tryConsume())
        XCTAssertTrue(bucket.tryConsume())
        XCTAssertTrue(bucket.tryConsume())
        XCTAssertFalse(bucket.tryConsume())
    }

    func testZeroCostClampsToOneNotUnlimitedBypass() {
        // A zero-cost consume must not bypass the limiter entirely.
        var bucket = TokenBucket(capacity: 1, refillRatePerSecond: 0)
        XCTAssertTrue(bucket.tryConsume(cost: 0))
        XCTAssertFalse(bucket.tryConsume(cost: 0))
    }

    func testRefillOverTimeUpToCapacity() {
        var now = Date(timeIntervalSince1970: 0)
        var bucket = TokenBucket(capacity: 2, refillRatePerSecond: 1, clock: { now })
        XCTAssertTrue(bucket.tryConsume(cost: 2))
        XCTAssertFalse(bucket.tryConsume())

        now = now.addingTimeInterval(1)
        XCTAssertTrue(bucket.tryConsume(), "should have refilled exactly 1 token after 1 second")
        XCTAssertFalse(bucket.tryConsume())
    }

    func testRefillDoesNotExceedCapacityAfterLongIdle() {
        var now = Date(timeIntervalSince1970: 0)
        var bucket = TokenBucket(capacity: 2, refillRatePerSecond: 100, clock: { now })
        _ = bucket.tryConsume(cost: 2)

        // Idle for a very long time — refill must cap at capacity, not
        // accumulate an enormous unbounded burst allowance.
        now = now.addingTimeInterval(10_000)
        XCTAssertTrue(bucket.tryConsume(cost: 2))
        XCTAssertFalse(bucket.tryConsume(), "bucket must not have accumulated more than capacity")
    }

    func testTimeUntilAvailableWhenTokensAlreadySufficient() {
        let bucket = TokenBucket(capacity: 5, refillRatePerSecond: 1)
        XCTAssertEqual(bucket.timeUntilAvailable(cost: 1), 0)
    }

    func testTimeUntilAvailableWithZeroRefillRateIsInfinite() {
        var bucket = TokenBucket(capacity: 1, refillRatePerSecond: 0)
        _ = bucket.tryConsume()
        XCTAssertEqual(bucket.timeUntilAvailable(), .infinity)
    }

    func testTimeUntilAvailableComputesExpectedDeficit() {
        var bucket = TokenBucket(capacity: 4, refillRatePerSecond: 2)
        _ = bucket.tryConsume(cost: 4)
        // Deficit of 2 tokens at 2 tokens/sec = 1 second.
        XCTAssertEqual(bucket.timeUntilAvailable(cost: 2), 1, accuracy: 0.001)
    }
}
