import Testing
import Foundation

/// PROBE ONLY (ROH-110) — delete with the probe branch.
///
/// Round 1 refuted "cancelling a child parked in `Task.sleep` aborts": 12,000 cancellations,
/// 0/20 processes died. Round 2 adds the two things the real `withTimeout` has and that repro
/// did not — a `@MainActor` caller (so the child closures are `@isolated(any)`, which is the
/// thunk named in the crash frames) and a generic element type.
@Suite("ROH-110 repro probe")
struct ROH110ReproProbe {
    struct Boom: Error {}

    /// D: MainActor caller, NON-generic element type.
    @MainActor
    @Test func mainActorNonGeneric() async {
        for _ in 0..<200 {
            try? await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await Task.sleep(for: .seconds(4)) }
                group.addTask { throw Boom() }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        }
    }

    /// E: MainActor caller, GENERIC element type — `withTimeout`'s exact shape, with the
    /// injected escaping async sleep seam, but no Aura types.
    @MainActor
    @Test func mainActorGeneric() async {
        for _ in 0..<200 {
            _ = try? await race(.seconds(4),
                                sleep: { try await Task.sleep(for: $0) },
                                operation: { () async throws -> Int in throw Boom() })
        }
    }

    /// F: same generic shape but called from a NON-isolated context, to separate "generic" from
    /// "isolated" as the culprit.
    @Test func nonisolatedGeneric() async {
        for _ in 0..<200 {
            _ = try? await race(.seconds(4),
                                sleep: { try await Task.sleep(for: $0) },
                                operation: { () async throws -> Int in throw Boom() })
        }
    }
}

private func race<T: Sendable>(
    _ duration: Duration,
    sleep: @Sendable @escaping (Duration) async throws -> Void,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await sleep(duration)
            throw ROH110ReproProbe.Boom()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw ROH110ReproProbe.Boom() }
        return first
    }
}
