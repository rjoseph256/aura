import Testing
import Foundation
import AuraCore

struct DeepLinkTests {
    private func parse(_ string: String) -> DeepLink? {
        DeepLink.parse(URL(string: string)!)
    }

    @Test func parsesTabAndRideHosts() {
        #expect(parse("aura://plan") == .home)
        #expect(parse("aura://history") == .history)
        #expect(parse("aura://settings") == .settings)
        #expect(parse("aura://ride") == .freeRide)
    }

    @Test func parsesPreviewIntoPlace() {
        guard case let .preview(place)? =
                parse("aura://preview?lat=40.44&lng=-79.99&name=Church%20Brew%20Works") else {
            Issue.record("expected .preview"); return
        }
        #expect(place.name == "Church Brew Works")
        #expect(place.coordinate.latitude == 40.44)
        #expect(place.coordinate.longitude == -79.99)
        #expect(place.category == .custom)
        #expect(place.isSaved == false)
    }

    @Test func previewMintsFreshIdEachParse() {
        let url = "aura://preview?lat=1&lng=2&name=A"
        guard case let .preview(a)? = parse(url), case let .preview(b)? = parse(url) else {
            Issue.record("expected two .preview"); return
        }
        #expect(a.id != b.id)
    }

    @Test func rejectsBadInput() {
        #expect(parse("aura://nope") == nil)                         // unknown host
        #expect(parse("https://preview?lat=1&lng=2&name=A") == nil)  // wrong scheme
        #expect(parse("aura://preview?lng=2&name=A") == nil)         // missing lat
        #expect(parse("aura://preview?lat=abc&lng=2&name=A") == nil) // non-numeric lat
        #expect(parse("aura://preview?lat=1&lng=2") == nil)          // missing name
        #expect(parse("aura://preview?lat=1&lng=2&name=") == nil)    // empty name
    }
}
