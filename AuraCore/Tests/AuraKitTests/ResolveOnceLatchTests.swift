import XCTest
@testable import AuraKit

/// Free function rather than a method: the concurrency test waits inside an unstructured
/// `Task`, and an instance method would capture the non-Sendable `XCTestCase`. Not named
/// `value(from:)` — that resolves to `NSObject.value(forKey:)` instead.
private func awaitedValue(of latch: ResolveOnceLatch<String>) async -> String {
    await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
        latch.attach(continuation)
    }
}

/// `ResolveOnceLatch` is public AuraKit API introduced under the ROH-126 coverage blocker,
/// and every one of its properties is the kind whose failure is a crash or a task that
/// never wakes — a double resume, or a resolution delivered to nobody. Two reviewers
/// reproduced a permanent suspend against an earlier version of `attach`, so the ordering
/// cases are pinned here rather than argued about in a comment.
final class ResolveOnceLatchTests: XCTestCase {

    func testAttachThenResolveDelivers() async {
        let latch = ResolveOnceLatch<String>()
        Task { latch.resolve("done") }
        let result = await awaitedValue(of: latch)
        XCTAssertEqual(result, "done")
    }

    /// The case the cancellation path made reachable: `withTaskCancellationHandler` runs
    /// `onCancel` before the body when the task is already cancelled, so the latch resolves
    /// before there is a continuation to resume. The outcome must be parked, not dropped.
    func testResolveBeforeAttachIsDeliveredAtAttach() async {
        let latch = ResolveOnceLatch<String>()
        latch.resolve("early")
        let result = await awaitedValue(of: latch)
        XCTAssertEqual(result, "early", "an outcome that arrived before the wait must survive to it")
    }

    func testFirstResolutionWins() async {
        let latch = ResolveOnceLatch<String>()
        latch.resolve("first")
        latch.resolve("second")
        latch.resolve("third")
        let result = await awaitedValue(of: latch)
        XCTAssertEqual(result, "first", "later resolutions are no-ops, never a second resume")
    }

    /// A resolve racing an attach must resume exactly once — resuming twice traps.
    func testConcurrentResolversResumeExactlyOnce() async {
        for _ in 0..<200 {
            let latch = ResolveOnceLatch<String>()
            let waiter = Task { await awaitedValue(of: latch) }
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<4 {
                    group.addTask { latch.resolve("r\(index)") }
                }
            }
            let result = await waiter.value
            XCTAssertTrue(result.hasPrefix("r"))
        }
    }

    /// A waiter arriving after the latch resolved is handed the outcome rather than
    /// parking on a latch that can never fire again. The earlier version stored the
    /// resolution in a field `attach` did not consult, so this suspended forever.
    func testAttachAfterResolutionStillResumes() async {
        let latch = ResolveOnceLatch<String>()
        latch.resolve("kept")

        let first = await awaitedValue(of: latch)
        XCTAssertEqual(first, "kept")

        // The outcome is retained, not consumed, so a second wait completes too.
        let second = await awaitedValue(of: latch)
        XCTAssertEqual(second, "kept", "the resolved outcome must outlive the first delivery")
    }
}
