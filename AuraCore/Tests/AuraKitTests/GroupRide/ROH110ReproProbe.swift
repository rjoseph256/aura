import Testing
import Foundation

/// PROBE ONLY (ROH-110) — delete with the probe branch.
///
/// Isolates the hypothesis that cancelling a child task parked in `Task.sleep` is what aborts
/// libswift_Concurrency's task allocator. Touches no Aura code: if this aborts, the defect is in
/// the toolchain/OS pair and `withTimeout` merely happened to be the caller that hit it.
@Suite("ROH-110 repro probe")
struct ROH110ReproProbe {
    struct Boom: Error {}

    /// A: cancel a child parked in a real `Task.sleep`, via a task group. This is exactly the
    /// shape the structured `withTimeout` produces on the operation-throws path.
    @Test func cancelChildParkedInRealSleep() async {
        for _ in 0..<200 {
            try? await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await Task.sleep(for: .seconds(4)) }
                group.addTask { throw Boom() }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        }
    }

    /// B: same, but the sleep is reached through an escaping async closure — the `sleep` seam's
    /// shape. Distinguishes "cancelling a sleep" from "cancelling a sleep behind a closure".
    @Test func cancelChildParkedInSleepBehindEscapingClosure() async {
        let sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        for _ in 0..<200 {
            try? await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await sleep(.seconds(4)) }
                group.addTask { throw Boom() }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        }
    }

    /// C: the unstructured shape the original `withTimeout` used — cancel a standalone `Task`
    /// parked in a sleep, then let the caller unwind.
    @Test func cancelUnstructuredTaskParkedInSleep() async {
        for _ in 0..<200 {
            let t = Task { try await Task.sleep(for: .seconds(4)) }
            t.cancel()
            _ = try? await t.value
        }
    }
}
