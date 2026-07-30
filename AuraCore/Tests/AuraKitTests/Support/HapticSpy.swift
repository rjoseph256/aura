import AuraCore
@testable import AuraKit

/// Records the cues a collaborator played. Shared by the guidance and coordinator suites.
final class HapticSpy: HapticPlaying {
    var cues: [RideHapticCue] = []
    var prepareCount = 0
    func prepare() { prepareCount += 1 }
    func play(_ cue: RideHapticCue) { cues.append(cue) }
}
