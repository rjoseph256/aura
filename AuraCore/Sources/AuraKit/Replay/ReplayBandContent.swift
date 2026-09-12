import AuraCore

/// What the scrub band draws under the playhead (spec D6). Built once by the entry modifier —
/// `ElevationProfile.classify` needs the flattened track, which must never be read in a `body`.
public struct ReplayBandContent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case silhouette([Double])
        case rail
    }
    public static let sampleCount = 240

    public let kind: Kind
    public let holds: [ReplayHold]

    public init(ride: Ride, timeline: ReplayTimeline) {
        let gain = ride.stats?.elevationGainMeters ?? 0
        if case .profile = ElevationProfile.classify(track: ride.flattenedPoints, gainMeters: gain),
           let samples = timeline.profile(sampleCount: Self.sampleCount) {
            kind = .silhouette(samples)
        } else {
            kind = .rail
        }
        holds = timeline.holds
    }
}
