import XCTest
@testable import RateLimitKit

final class LocalRequestQueueTests: XCTestCase {

    private func makeRequest(_ payload: String) -> BackpressureRequest {
        BackpressureRequest(coalescingKey: payload, payload: payload)
    }

    func testZeroAndNegativeCapacityClampToOne() async {
        let q1 = LocalRequestQueue(capacity: 0)
        let q2 = LocalRequestQueue(capacity: -5)
        // A capacity-1 queue should accept exactly one item before overflow.
        let dropped1 = await q1.enqueue(makeRequest("a"))
        XCTAssertNil(dropped1)
        let dropped2 = await q2.enqueue(makeRequest("a"))
        XCTAssertNil(dropped2)
    }

    func testEmptyQueueDequeueReturnsNilNotCrash() async {
        let queue = LocalRequestQueue()
        let result = await queue.dequeue()
        XCTAssertNil(result)
    }

    func testEmptyQueuePeekReturnsNilNotCrash() async {
        let queue = LocalRequestQueue()
        let result = await queue.peek()
        XCTAssertNil(result)
    }

    func testFIFOOrdering() async {
        let queue = LocalRequestQueue(capacity: 10)
        let first = makeRequest("first")
        let second = makeRequest("second")
        await queue.enqueue(first)
        await queue.enqueue(second)
        let dequeued = await queue.dequeue()
        XCTAssertEqual(dequeued?.id, first.id)
    }

    func testDropOldestOverflowPolicy() async {
        let queue = LocalRequestQueue(capacity: 2, overflowPolicy: .dropOldest)
        let first = makeRequest("first")
        let second = makeRequest("second")
        let third = makeRequest("third")

        await queue.enqueue(first)
        await queue.enqueue(second)
        let dropped = await queue.enqueue(third)

        XCTAssertEqual(dropped?.id, first.id, "oldest entry should be evicted")
        let remaining = await queue.all()
        XCTAssertEqual(remaining.map(\.id), [second.id, third.id])
    }

    func testRejectNewestOverflowPolicy() async {
        let queue = LocalRequestQueue(capacity: 2, overflowPolicy: .rejectNewest)
        let first = makeRequest("first")
        let second = makeRequest("second")
        let third = makeRequest("third")

        await queue.enqueue(first)
        await queue.enqueue(second)
        let dropped = await queue.enqueue(third)

        XCTAssertEqual(dropped?.id, third.id, "the new request itself should be rejected")
        let remaining = await queue.all()
        XCTAssertEqual(remaining.map(\.id), [first.id, second.id])
    }

    func testPeekDoesNotRemove() async {
        let queue = LocalRequestQueue()
        let request = makeRequest("only")
        await queue.enqueue(request)
        let peeked = await queue.peek()
        XCTAssertEqual(peeked?.id, request.id)
        XCTAssertEqual(await queue.count, 1, "peek must not remove the item")
    }
}
