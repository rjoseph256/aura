import Foundation
import Testing
import AuraCore

struct DeepLinkJoinTests {
    @Test func parsesValidJoinCode() {
        let url = URL(string: "aura://join?code=7K2Q9FX3")!
        #expect(DeepLink.parse(url) == .join(JoinCode(rawValue: "7K2Q9FX3")!))
    }
    @Test func rejectsInvalidCode() {
        // lowercase / ambiguous glyphs fail JoinCode validation -> nil (no-op link)
        #expect(DeepLink.parse(URL(string: "aura://join?code=abc")!) == nil)
    }
    @Test func rejectsMissingCode() {
        #expect(DeepLink.parse(URL(string: "aura://join")!) == nil)
    }
}
