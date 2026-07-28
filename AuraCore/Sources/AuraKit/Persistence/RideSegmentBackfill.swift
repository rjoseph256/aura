import Foundation
import SwiftData
import os
import AuraCore

/// Fills `segmentsData` on `RideRecord` rows that do not have it, by wrapping each row's flat
/// `trackData` in a single segment (spec D2).
///
/// **Why this is not a migration stage.** Spec D2 and ROH-100 both put this backfill in the
/// V5→V6 `didMigrate`. Three problems, each fatal on its own:
///
/// - `didMigrate` runs inside `ModelContainer.init`, which `AuraApp.init()` calls before the
///   first frame. Decoding and re-encoding a rider's whole history there is tens of seconds of
///   black screen on a long history, and the watchdog kill repeats on every launch.
/// - A throw inside a stage fails the container, and the app catches that by falling back to
///   an in-memory store: the rider's History reads as empty and the widget snapshot is
///   overwritten with nothing. A best-effort backfill must not be able to reach that.
/// - A stage runs once. Rides recorded on a V5 device *after* the migration keep arriving by
///   CloudKit with `segmentsData` nil, and `RideStore.save` only ever rewrites rows this build
///   wrote — so only something re-runnable can ever finish the job, which is the precondition
///   for retiring `trackData`.
///
/// **Call it from a detached task.** `run` is synchronous and does its work on the calling
/// thread, with a `ModelContext` it creates and owns, so a `Task.detached` puts the whole sweep
/// on a background thread. A `Task { }` started inside a SwiftUI `.task` would inherit MainActor
/// isolation and run it on the main thread instead.
///
/// **It is NOT a `@ModelActor`, and that is now just a simplification.** It was one, and it was
/// rewritten to this shape while chasing ROH-110, on the theory that the detached-to-actor hop
/// caused the task-allocator abort on the macOS 15 CI runner. That theory was wrong — the abort
/// came from an `async` closure passed as a default argument (see `GroupRideSession.sleep`), and
/// `main` kept failing after the actor was gone. The plain `ModelContext` is kept because owning
/// a context outright is simpler than an actor here, not because the actor was dangerous.
///
/// **What it guarantees.** It fills a nil column and nothing else, re-checking that the column
/// is still nil immediately before writing, and it saves one row at a time so a row is dirty
/// for microseconds rather than for a batch. That matters because CoreData resolves a conflict
/// in favour of the *dirty* object's snapshot: any other writer of the same row — in practice
/// the CloudKit import context — that commits while a row sits dirty here would have its
/// values reverted by this save. Per-row saves shrink that window to the save itself; they do
/// not close it, and there is no merge-policy knob in SwiftData to close it with.
///
/// **What it does not guarantee.** `segmentsData` is derived from `trackData` at one instant,
/// and nothing re-derives it afterwards. A V5 device that checkpoints a ride mid-pause,
/// syncs the partial track, and finishes the ride later can leave a row whose `segmentsData`
/// (backfilled here from the partial track) is shorter than its own `trackData` — and reads
/// prefer `segmentsData`. The settling window below is what keeps that narrow; closing it
/// entirely would need a derivation marker, which is a column and therefore another CloudKit
/// promotion. Recorded rather than pretended away.
public enum RideSegmentBackfill {
    private static let log = Logger(subsystem: "app.aura.kit", category: "backfill")

    /// Consecutive failed writes before the run gives up. A full disk fails every save, and
    /// grinding through a whole history to write nothing is pure battery.
    private static let writeFailureLimit = 3

    /// How long a ride is left alone before it is considered settled. A ride still being
    /// recorded — or paused — on another device syncs down in pieces, and backfilling from a
    /// piece is what produces the desync described above.
    public static let defaultSettlingWindow: TimeInterval = 24 * 60 * 60

    public struct Result: Equatable, Sendable {
        /// Rows given a `segmentsData` blob by this run.
        public var backfilled: Int
        /// Rows whose flat track could not be decoded. They stay nil and read through the
        /// mapper's fallback, exactly as they did before V6 — and they will be retried, and
        /// fail again, on every later run. A non-zero count here is worth investigating.
        public var unreadable: Int
        /// Rows whose write failed (a full disk, most likely). Retried on a later run.
        public var failedWrites: Int
        /// Rows still without `segmentsData` when the run ended — the budget ran out, the run
        /// was cancelled, the row is not settled yet, or it is one of the two counts above.
        /// Counted from the store at the end, so it cannot disagree with reality.
        public var remaining: Int

        public init(backfilled: Int = 0, unreadable: Int = 0,
                    failedWrites: Int = 0, remaining: Int = 0) {
            self.backfilled = backfilled
            self.unreadable = unreadable
            self.failedWrites = failedWrites
            self.remaining = remaining
        }
    }

    /// Backfills settled rows one at a time, yielding periodically, until the budget runs out
    /// or the task is cancelled.
    ///
    /// - Parameters:
    ///   - maxRows: how many rows this run may *fill*. Unreadable and unsettled rows do not
    ///     spend it — otherwise a handful of corrupt rows at the front would consume the whole
    ///     budget on every run and the rows behind them would never be reached. Every filled
    ///     row is also a CloudKit export, so a caller keeps this small to spread a long
    ///     history — and the export cost — over several launches.
    ///   - settledBefore: rows that started at or after this are left for a later run.
    /// - Returns: what the run did. Never throws: a backfill that could fail its caller would
    ///   be worse than no backfill at all.
    /// - Parameter isCancelled: checked before every row, so a caller can stop the sweep. Defaults
    ///   to the ambient task's cancellation, which is what `AuraApp` cancels when a ride starts.
    @discardableResult
    public static func run(container: ModelContainer,
                           maxRows: Int = .max,
                           settledBefore: Date = Date().addingTimeInterval(-defaultSettlingWindow),
                           isCancelled: () -> Bool = { Task.isCancelled }) -> Result {
        let modelContext = ModelContext(container)
        var result = Result()
        let pending: [UUID]
        do {
            pending = try pendingRideIDs(modelContext)
        } catch {
            Self.log.error("backfill: could not list pending rides: \(error, privacy: .public)")
            return result
        }
        guard !pending.isEmpty else { return result }

        var consecutiveWriteFailures = 0
        sweep: for id in pending {
            guard result.backfilled < maxRows, !isCancelled() else { break }
            switch fill(id: id, settledBefore: settledBefore, modelContext: modelContext) {
            case .filled:
                result.backfilled += 1
                consecutiveWriteFailures = 0
            case .unreadable:
                result.unreadable += 1
            case .writeFailed:
                result.failedWrites += 1
                consecutiveWriteFailures += 1
                if consecutiveWriteFailures >= Self.writeFailureLimit {
                    Self.log.error("backfill: \(consecutiveWriteFailures) writes failed in a row — stopping")
                    break sweep
                }
            case .notSettledYet, .alreadyFilled:
                break
            }
        }

        result.remaining = (try? pendingCount(modelContext)) ?? 0
        Self.log.info("""
            backfill: \(result.backfilled) filled, \(result.unreadable) unreadable, \
            \(result.failedWrites) write failures, \(result.remaining) still pending
            """)
        return result
    }

    private enum RowOutcome { case filled, unreadable, writeFailed, notSettledYet, alreadyFilled }

    /// One row at a time, by id. `#Predicate { $0.id == id }` is the only predicate shape this
    /// store already relies on (`RideStore.save`), and the encode happens *before* the row is
    /// dirtied so the write window is the save itself.
    private static func fill(id: UUID, settledBefore: Date, modelContext: ModelContext) -> RowOutcome {
        do {
            let descriptor = FetchDescriptor<RideRecord>(predicate: #Predicate { $0.id == id })
            // Re-checked here, not just in the pending query: another sweep, or a CloudKit
            // import, may have filled this row since the pending list was taken.
            guard let record = try modelContext.fetch(descriptor).first,
                  record.segmentsData == nil else { return .alreadyFilled }
            guard record.startedAt < settledBefore else { return .notSettledYet }

            // An empty blob is left alone rather than stamped as an empty ride. It reads as an
            // empty ride either way (`RideMapper`), and a row CloudKit has materialized without
            // its asset yet would otherwise be frozen empty forever — `segmentsData` wins on
            // read, and nothing re-derives it.
            guard !record.trackData.isEmpty else { return .notSettledYet }
            guard let points = try? JSONDecoder().decode([TrackPoint].self, from: record.trackData) else {
                Self.log.error("""
                    backfill: undecodable trackData for ride \(id, privacy: .public); \
                    left nil, the read path still falls back to the flat track
                    """)
                return .unreadable
            }
            // Zero points is ZERO segments, never one empty segment — `Ride`'s canonical
            // encoding, so a backfilled fix-less ride round-trips equal to a fresh one.
            let encoded = try JSONEncoder().encode(points.isEmpty ? [] : [RideSegment(points: points)])
            record.segmentsData = encoded
            try modelContext.save()
            return .filled
        } catch {
            Self.log.error("backfill: ride \(id, privacy: .public) failed: \(error, privacy: .public)")
            modelContext.rollback()
            return .writeFailed
        }
    }

    private static func pendingDescriptor() -> FetchDescriptor<RideRecord> {
        FetchDescriptor<RideRecord>(predicate: #Predicate { $0.segmentsData == nil })
    }

    private static func pendingRideIDs(_ modelContext: ModelContext) throws -> [UUID] {
        // Reading `id` does not fault either external blob, so listing the work is cheap even
        // on a long history. The rows themselves do register in this context.
        try modelContext.fetch(pendingDescriptor()).map(\.id)
    }

    private static func pendingCount(_ modelContext: ModelContext) throws -> Int {
        try modelContext.fetchCount(pendingDescriptor())
    }
}
