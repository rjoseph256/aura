import Foundation
import Supabase
import AuraCore
import AuraKit

/// Live Supabase implementation of the SP2 transport. Publishes via `record_track_points`
/// (which broadcasts), seeds via `ride_live_snapshot`, and bridges the ride's private
/// Realtime channel into `TransportEvent`s. Owns reconnect/backoff and re-emits
/// `.connected`/`.disconnected`. `nonisolated` — pure backend I/O under default-MainActor.
public nonisolated struct SupabaseRideSessionTransport: RideSessionTransport {
    private let client: SupabaseClient
    public init(client: SupabaseClient = SupabaseClientProvider.shared) { self.client = client }

    @MainActor
    public func liveSubscription(rideID: UUID) -> any RideLiveSubscription {
        SupabaseRideLiveSubscription(client: client, rideID: rideID)
    }

    public func snapshot(rideID: UUID) async throws -> [LivePositionPayload] {
        let rows: [SnapshotRow] = try await client
            .rpc("ride_live_snapshot", params: ["p_ride_id": rideID.uuidString])
            .execute().value
        return rows.map { $0.toPayload() }
    }

    public func publish(rideID: UUID, points: [LivePositionPayload]) async throws {
        let formatter = ISO8601DateFormatter()
        let payload: [AnyJSON] = points.map { p in
            .object([
                "recorded_at": .string(formatter.string(from: p.recordedAt)),
                "lat": .double(p.coordinate.latitude),
                "lon": .double(p.coordinate.longitude),
                "progress_meters": .double(p.progressMeters),
                "motion_state": .string(p.motionState.rawValue)
            ])
        }
        _ = try await client.rpc("record_track_points",
            params: ["p_ride_id": AnyJSON.string(rideID.uuidString),
                     "p_points": AnyJSON.array(payload)]).execute()
    }
}

/// Wire row from ride_live_snapshot. snake_case -> domain. motion_state is not stored
/// in the snapshot, so peers seed as `.moving`; the next broadcast delta refines it.
private nonisolated struct SnapshotRow: Decodable {
    let userID: UUID
    let lat: Double
    let lon: Double
    let progressMeters: Double
    let recordedAt: Date
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case lat, lon
        case progressMeters = "progress_meters"
        case recordedAt = "recorded_at"
    }
    func toPayload() -> LivePositionPayload {
        LivePositionPayload(userID: userID,
                            coordinate: Coordinate(latitude: lat, longitude: lon),
                            progressMeters: progressMeters, recordedAt: recordedAt,
                            motionState: .moving)
    }
}

/// Owns one ride's RealtimeChannelV2 and bridges its broadcast streams into TransportEvents,
/// including a bounded-backoff reconnect loop. Teardown via cancel()/deinit finishes the
/// stream and unsubscribes the channel.
///
/// **API verification status (supabase-swift pinned to majorVersion: 2):**
/// - `client.realtimeV2.channel(_:options:)` — BEST-GUESS. Channel constructor shape and
///   `isPrivate` option name must be confirmed against the SDK source on first build.
/// - `channel.broadcastStream(event:)` returning `AsyncStream<[String: AnyJSON]>` — BEST-GUESS.
///   Return element type may differ (e.g. a `RealtimeMessage` struct). CI app-build gates this.
/// - `channel.subscribe()` — BEST-GUESS; may be named `join()` in some minor versions.
/// - `AnyJSON` accessors `.stringValue`, `.doubleValue`, `.objectValue` — BEST-GUESS;
///   confirmed present in supabase-swift v2 Helpers but exact API shape needs the resolved source.
/// - Broadcast envelope shape — BEST-GUESS; `body(of:)` reads from `"payload"` with a flat
///   fallback. DEVICE-VERIFY required: the nested-encode decode cannot be caught by compile.
@MainActor
private final class SupabaseRideLiveSubscription: RideLiveSubscription {
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private var pump: Task<Void, Never>?

    init(client: SupabaseClient, rideID: UUID) {
        var cont: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
        let cont2 = continuation
        pump = Task { [cont2] in
            await SupabaseRideLiveSubscription.runPump(
                client: client, rideID: rideID, continuation: cont2)
        }
    }

    private static func runPump(
        client: SupabaseClient,
        rideID: UUID,
        continuation cont2: AsyncStream<TransportEvent>.Continuation?
    ) async {
        let topic = "ride:\(rideID.uuidString)"
        var delay: UInt64 = 1_000_000_000 // 1 s
        let maxDelay: UInt64 = 30_000_000_000 // 30 s
        let maxAttempts = 8
        var attempt = 0

        while attempt <= maxAttempts, !Task.isCancelled {
            if attempt > 0 {
                // Yield disconnected before each retry so the session can surface
                // "live sharing unavailable" to the UI without waiting for reconnect.
                cont2?.yield(.disconnected(nil))
                delay = await backoffDelay(current: delay, max: maxDelay)
                if Task.isCancelled { break }
            }

            await runChannelAttempt(client: client, topic: topic, continuation: cont2)

            if Task.isCancelled { break }

            // Channel streams drained normally — channel closed. Retry.
            cont2?.yield(.disconnected(
                LiveTransportError("channel closed; reconnecting (attempt \(attempt + 1))")))
            attempt += 1
            delay = 1_000_000_000 // reset backoff after a successful connect
        }

        // Exhausted retries or cancelled — emit a terminal disconnected and finish.
        if !Task.isCancelled {
            cont2?.yield(.disconnected(LiveTransportError("reconnect limit reached")))
        }
        cont2?.finish()
    }

    /// Sleeps for `current` nanoseconds then returns the next (doubled, capped) delay value.
    private static func backoffDelay(current: UInt64, max maxDelay: UInt64) async -> UInt64 {
        try? await Task.sleep(nanoseconds: current)
        return min(current * 2, maxDelay)
    }

    /// Builds the private Realtime channel, subscribes, drains broadcast streams,
    /// and returns when the channel closes or the Task is cancelled.
    private static func runChannelAttempt(
        client: SupabaseClient,
        topic: String,
        continuation cont2: AsyncStream<TransportEvent>.Continuation?
    ) async {
        // UNVERIFIED: channel options closure shape and isPrivate property name.
        let channel = client.realtimeV2.channel(topic) { opts in
            opts.isPrivate = true
        }

        // UNVERIFIED: broadcastStream(event:) return element type ([String: AnyJSON]).
        let positions = channel.broadcastStream(event: "position")
        let lefts = channel.broadcastStream(event: "member_left")

        let positionTask = Task {
            for await message in positions {
                guard !Task.isCancelled else { break }
                if let payload = livePosition(from: message) {
                    cont2?.yield(.position(payload))
                }
            }
        }
        let leftTask = Task {
            for await message in lefts {
                guard !Task.isCancelled else { break }
                if let id = memberLeftUserID(from: message) {
                    cont2?.yield(.memberLeft(id))
                }
            }
        }

        // UNVERIFIED: subscribe() name and whether it throws.
        await channel.subscribe()
        cont2?.yield(.connected)

        // Wait until both broadcast streams drain (channel closed/cancelled).
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await positionTask.value }
            group.addTask { await leftTask.value }
        }
    }

    func cancel() {
        pump?.cancel()
        pump = nil
        continuation.finish()
    }

    deinit {
        pump?.cancel()
        continuation.finish()
    }

    // The Realtime broadcast envelope may nest the app data under a "payload" key, or the
    // SDK may hand broadcastStream already-unwrapped field values. This helper reads from
    // the nested object first, then falls back to the flat message, so both shapes work.
    // DEVICE-VERIFY: confirm which envelope shape the pinned SDK version produces.
    private static func body(of message: [String: AnyJSON]) -> [String: AnyJSON] {
        message["payload"]?.objectValue ?? message
    }

    /// Decodes a live position from a broadcast message.
    /// DEVICE-VERIFY: field names must match the record_track_points broadcast payload
    /// (userID, lat, lon, progressMeters, recordedAt ISO8601, motionState).
    private static func livePosition(from message: [String: AnyJSON]) -> LivePositionPayload? {
        let m = body(of: message)
        guard let userIDStr = m["userID"]?.stringValue,
              let userID = UUID(uuidString: userIDStr),
              let lat = m["lat"]?.doubleValue,
              let lon = m["lon"]?.doubleValue,
              let progress = m["progressMeters"]?.doubleValue,
              let recordedAtStr = m["recordedAt"]?.stringValue,
              let recordedAt = ISO8601DateFormatter().date(from: recordedAtStr),
              let motionRaw = m["motionState"]?.stringValue,
              let motion = MotionState(rawValue: motionRaw)
        else { return nil }
        return LivePositionPayload(
            userID: userID,
            coordinate: Coordinate(latitude: lat, longitude: lon),
            progressMeters: progress,
            recordedAt: recordedAt,
            motionState: motion
        )
    }

    private static func memberLeftUserID(from message: [String: AnyJSON]) -> UUID? {
        body(of: message)["userID"]?.stringValue.flatMap(UUID.init)
    }
}

/// Sendable error for `.disconnected` (bare `Error` is not Sendable, and TransportEvent
/// crosses the actor boundary). The reconnect loop wraps caught errors in this type.
public struct LiveTransportError: Error, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}
