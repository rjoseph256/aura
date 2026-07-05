import Testing
import Foundation
import AuraCore
@testable import AuraKit

private actor CallLog { private(set) var coords: [Coordinate] = []; func add(_ c: Coordinate) { coords.append(c) } }
private struct RecordingProvider: GemProviding {
    let log: CallLog
    let gems: [Gem]
    func gems(near coordinate: Coordinate) async -> [Gem] { await log.add(coordinate); return gems }
}
private struct NoSeen: SeenGemStoring { func seenGemIDs() -> Set<String> { [] }; func markSeen(_ id: String, at date: Date) {} }
private struct NoHaptic: GemHapticPlaying { func playGemSurfaced() {} }

@MainActor
@Suite("GemDiscoveryStore load deferral")
struct GemDiscoveryStoreLoadTests {
    @Test func neverQueriesBeforeFirstFix() async {
        let log = CallLog()
        let store = GemDiscoveryStore(provider: RecordingProvider(log: log, gems: []),
                                      seen: NoSeen(), haptics: NoHaptic())
        // No update() yet → no load task fired, so nothing queried Null Island.
        #expect(store.loadTask == nil)
        #expect(await log.coords.isEmpty)
    }

    @Test func loadsOnceAtFirstRealCoordinate() async {
        let log = CallLog()
        let p = Coordinate(latitude: 40.44, longitude: -79.99)
        let store = GemDiscoveryStore(provider: RecordingProvider(log: log, gems: []),
                                      seen: NoSeen(), haptics: NoHaptic())
        store.update(at: p, now: Date(timeIntervalSince1970: 1))
        store.update(at: p, now: Date(timeIntervalSince1970: 2))
        await store.loadTask?.value            // deterministic barrier — no wall-clock sleep
        let coords = await log.coords
        #expect(coords.count == 1)                 // exactly one load
        #expect(coords.first?.latitude == 40.44)   // never (0,0)
    }
}
