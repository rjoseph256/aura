import AuraCore

/// Classifies a ride's elevation into what the summary and share card should draw.
/// The profile/flat decision keys on **cumulative climb** (`gainMeters`) — the same
/// number both surfaces put on the callout — so the label and the number can never
/// contradict on screen. Gain-gating also excludes the flat-trace "solid bar" failure
/// mode: a near-flat series can't clear the climb floor, so `.profile` never receives
/// a flat trace. Pure + testable; shared so the two surfaces never diverge.
public enum ElevationProfile {
    /// Minimum cumulative climb (meters) to headline an elevation profile. Tunable;
    /// settled during the on-device pass.
    public static let minGainMeters = 10.0

    public enum Kind: Equatable, Sendable {
        case profile([Double])   // gain ≥ floor, ≥2 samples: draw the silhouette
        case flat                // ≥2 samples but gain < floor: "Mostly flat"
        case unavailable         // < 2 elevation samples: omit the section
    }

    /// `gainMeters` is the ride's cumulative ascent (`RideStats.elevationGainMeters`);
    /// `track` supplies the elevation samples the silhouette is drawn from.
    public static func classify(track: [TrackPoint], gainMeters: Double) -> Kind {
        let elevations = track.compactMap(\.elevation)
        guard elevations.count >= 2 else { return .unavailable }
        return gainMeters >= minGainMeters ? .profile(elevations) : .flat
    }
}
