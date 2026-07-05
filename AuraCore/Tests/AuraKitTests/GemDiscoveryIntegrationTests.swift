import Testing
import Foundation
import AuraCore
@testable import AuraKit

/// Builds the PRODUCTION-STYLE provider assembly (the same shape RideHUDView wires up:
/// CompositeGemProvider(local: [PersonalGemProvider, CuratedGemProvider], live: LiveGemProvider))
/// and drives GemDiscoveryStore end-to-end. This exists specifically to close the "unit-green
/// but prod-dead" gap class the whole-branch review found — no individual provider's unit
/// tests can catch the app never wiring them together, so this test exercises the real
/// composition instead of a hand-built single stub.
@MainActor
@Suite("Gem discovery — production assembly integration")
struct GemDiscoveryIntegrationTests {
    private struct StubResurfaceReading: ResurfacePlacesReading {
        let places: [SavedPlace]
        func resurfacePlaces() -> [SavedPlace] { places }
    }

    @Test func personalGemSurfacesThroughTheRealProviderAssembly() async {
        let rider = Coordinate(latitude: 40.44, longitude: -79.99)
        let resurfacePlace = SavedPlace(
            id: UUID(), name: "My Favorite Overlook", subtitle: nil,
            coordinate: rider, category: .custom, kind: .favorite,
            savedAt: Date(timeIntervalSince1970: 0), resurface: true)

        let provider = CompositeGemProvider(
            local: [PersonalGemProvider(reading: StubResurfaceReading(places: [resurfacePlace])),
                    CuratedGemProvider(bundle: .module)],
            live: LiveGemProvider(session: emptySession()))

        let store = GemDiscoveryStore(
            provider: provider,
            seen: InMemorySeen(),
            haptics: SpyHaptics())

        // A single update() both fires the deferred load and evaluates against the loaded
        // candidates (load() ends with an internal evaluate()) — matches the real
        // RideDiscoverySink call from a location tick.
        let now = Date(timeIntervalSince1970: 1_000)
        store.update(at: rider, now: now)
        await store.loadTask?.value

        let personalGemID = "personal:\(resurfacePlace.id.uuidString)"
        #expect(store.visiblePins.contains { $0.id == personalGemID })
        #expect(store.activeCard?.id == personalGemID)
    }

    private func emptySession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [EmptyResponseURLProtocol.self]
        return URLSession(configuration: cfg)
    }
}

/// Always answers 200 with an empty Overpass element set — stands in for "live" in the
/// production assembly without touching the network.
private final class EmptyResponseURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: #"{"elements":[]}"#.data(using: .utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
