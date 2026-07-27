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
/// So: a `@ModelActor`, off the main actor and off the launch path, batched, resumable, and
/// non-throwing. Resumability needs no bookkeeping — a row is pending precisely while its
/// `segmentsData` is nil, so a kill mid-sweep costs at most the current batch.
///
/// It is safe to run more than once and safe to run concurrently with normal ride writes: it
/// only ever fills a nil column, and re-checks that the column is still nil immediately before
/// writing.
@ModelActor
public actor RideSegmentBackfiller {
    private static let log = Logger(subsystem: "app.aura.kit", category: "backfill")

    public struct Result: Equatable, Sendable {
        /// Rows given a `segmentsData` blob by this run.
        public var backfilled: Int
        /// Rows whose flat track could not be decoded. They stay nil and read through the
        /// mapper's fallback, exactly as they did before V6.
        public var skipped: Int
        /// Rows still pending when `maxRows` ran out. A later run picks them up.
        public var remaining: Int

        public init(backfilled: Int = 0, skipped: Int = 0, remaining: Int = 0) {
            self.backfilled = backfilled
            self.skipped = skipped
            self.remaining = remaining
        }
    }

    /// Backfills pending rows, saving every `batchSize` rows and yielding between batches.
    ///
    /// - Parameters:
    ///   - batchSize: how many rows to modify before saving. This is the memory lever: dirty
    ///     objects hold their blobs until the save, and a ride's two blobs are ~1 MB each on a
    ///     three-hour ride. Small on purpose.
    ///   - maxRows: a per-run budget. Every backfilled row is also a CloudKit export, so a
    ///     caller can spread a very long history over several launches.
    /// - Returns: what the run did. Never throws: a backfill that could fail its caller would
    ///   be worse than no backfill at all.
    @discardableResult
    public func backfill(batchSize: Int = 10, maxRows: Int = .max) async -> Result {
        var result = Result()
        let pending: [UUID]
        do {
            pending = try pendingRideIDs()
        } catch {
            Self.log.error("backfill: could not list pending rides: \(error, privacy: .public)")
            return result
        }
        guard !pending.isEmpty else { return result }

        var dirty = 0
        for (index, id) in pending.enumerated() {
            guard index < maxRows else {
                result.remaining = pending.count - index
                break
            }
            switch backfillRide(id: id) {
            case .backfilled: result.backfilled += 1; dirty += 1
            case .skipped: result.skipped += 1
            case .alreadyDone: break
            }
            if dirty >= batchSize {
                save(&result, dirtyRows: &dirty)
                await Task.yield()
            }
        }
        save(&result, dirtyRows: &dirty)
        Self.log.info("""
            backfill: \(result.backfilled) filled, \(result.skipped) unreadable, \
            \(result.remaining) left for a later run
            """)
        return result
    }

    private enum RowOutcome { case backfilled, skipped, alreadyDone }

    /// One row at a time, by id. `#Predicate { $0.id == id }` is the only predicate shape this
    /// store already relies on (`RideStore.save`), and per-row fetching is what keeps the
    /// working set to the rows in the current batch.
    private func backfillRide(id: UUID) -> RowOutcome {
        do {
            let descriptor = FetchDescriptor<RideRecord>(predicate: #Predicate { $0.id == id })
            // Re-checked here, not just in the pending query: a normal ride write may have
            // filled this row since the sweep started.
            guard let record = try modelContext.fetch(descriptor).first,
                  record.segmentsData == nil else { return .alreadyDone }

            let points: [TrackPoint]
            if record.trackData.isEmpty {
                // What CloudKit materializes for a record that never carried the key. An empty
                // ride, not a corrupt one.
                points = []
            } else if let decoded = try? JSONDecoder().decode([TrackPoint].self, from: record.trackData) {
                points = decoded
            } else {
                Self.log.error("""
                    backfill: undecodable trackData for ride \(id, privacy: .public); \
                    left nil, the read path still falls back to the flat track
                    """)
                return .skipped
            }
            // Zero points is ZERO segments, never one empty segment — `Ride`'s canonical
            // encoding, so a backfilled fix-less ride round-trips equal to a fresh one.
            let segments = points.isEmpty ? [] : [RideSegment(points: points)]
            record.segmentsData = try JSONEncoder().encode(segments)
            return .backfilled
        } catch {
            Self.log.error("backfill: ride \(id, privacy: .public) failed: \(error, privacy: .public)")
            return .skipped
        }
    }

    private func pendingRideIDs() throws -> [UUID] {
        let descriptor = FetchDescriptor<RideRecord>(predicate: #Predicate { $0.segmentsData == nil })
        // Reading `id` does not fault either external blob, so listing the work is cheap even
        // on a long history.
        return try modelContext.fetch(descriptor).map(\.id)
    }

    /// A failed save costs this batch, not the run and never the caller. The rows it covered
    /// stay nil, so the next run simply finds them again.
    private func save(_ result: inout Result, dirtyRows: inout Int) {
        guard dirtyRows > 0 else { return }
        do {
            try modelContext.save()
        } catch {
            Self.log.error("backfill: batch save failed: \(error, privacy: .public)")
            modelContext.rollback()
            result.backfilled -= dirtyRows
            result.skipped += dirtyRows
        }
        dirtyRows = 0
    }
}
