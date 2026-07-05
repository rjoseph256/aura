import Testing
import Foundation
import AuraCore
@testable import AuraKit

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var body: Data = Data()
    nonisolated(unsafe) static var status: Int = 200
    static func set(status: Int, body: Data) { Self.status = status; Self.body = body }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("LiveGemProvider", .serialized)
struct LiveGemProviderTests {
    private func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    @Test func decodesLiveGemsCappedAtTier2() async {
        StubURLProtocol.set(status: 200, body: Data())
        StubURLProtocol.body = """
        {"elements":[{"type":"node","id":7,"lat":40.44,"lon":-79.99,"tags":{"tourism":"viewpoint","name":"Grandview"}}]}
        """.data(using: .utf8)!
        let provider = LiveGemProvider(session: session())
        let gems = await provider.gems(near: Coordinate(latitude: 40.44, longitude: -79.99))
        #expect(gems.count == 1)
        #expect(gems.first?.tier == .card)
        #expect(gems.first?.source == .live)
        #expect(gems.first?.id == "osm:node/7")
    }

    @Test func serverErrorYieldsEmpty() async {
        StubURLProtocol.set(status: 503, body: Data())
        let provider = LiveGemProvider(session: session())
        let gems = await provider.gems(near: Coordinate(latitude: 40.44, longitude: -79.99))
        #expect(gems.isEmpty)
    }

    @Test func unmappedElementsDropped() async {
        StubURLProtocol.set(status: 200, body: Data())
        StubURLProtocol.body = """
        {"elements":[{"type":"node","id":8,"lat":40.44,"lon":-79.99,"tags":{"shop":"bakery"}}]}
        """.data(using: .utf8)!
        let provider = LiveGemProvider(session: session())
        #expect(await provider.gems(near: Coordinate(latitude: 40.44, longitude: -79.99)).isEmpty)
    }
}
