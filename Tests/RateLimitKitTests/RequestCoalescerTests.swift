import XCTest
@testable import RateLimitKit

final class RequestCoalescerTests: XCTestCase {

    func testConcurrentCallsWithSameKeyShareOneUnderlyingCall() async {
        let coalescer = RequestCoalescer()
        let callCounter = CallCounter()

        async let first = coalescer.execute(key: "profile") {
            await callCounter.increment()
            return .success("a")
        }
        async let second = coalescer.execute(key: "profile") {
            await callCounter.increment()
            return .success("b")
        }

        let results = await [first, second]
        XCTAssertEqual(results[0], results[1], "both callers should see the same coalesced result")
        let count = await callCounter.value
        XCTAssertEqual(count, 1, "only one underlying operation should have run")
    }

    func testDifferentKeysRunIndependently() async {
        let coalescer = RequestCoalescer()
        let callCounter = CallCounter()

        async let first = coalescer.execute(key: "a") {
            await callCounter.increment()
            return .success("a")
        }
        async let second = coalescer.execute(key: "b") {
            await callCounter.increment()
            return .success("b")
        }

        _ = await [first, second]
        let count = await callCounter.value
        XCTAssertEqual(count, 2, "distinct keys must not be coalesced together")
    }

    func testSequentialCallsWithSameKeyEachRunIndependently() async {
        // Once the first call completes and clears itself out of
        // `inFlight`, a *later, non-overlapping* call for the same key must
        // run its own operation rather than incorrectly reusing a stale
        // result.
        let coalescer = RequestCoalescer()
        let first = await coalescer.execute(key: "k") { .success("first") }
        let second = await coalescer.execute(key: "k") { .success("second") }
        XCTAssertEqual(first, .success("first"))
        XCTAssertEqual(second, .success("second"))
    }
}

private actor CallCounter {
    private(set) var value = 0
    func increment() {
        value += 1
    }
}
