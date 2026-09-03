import Testing
import Foundation
@testable import AuraCore

struct JoinCodePasteTests {
    @Test func aSharedLinkYieldsItsCode() {
        #expect(JoinCodePaste.extract("aura://join?code=AB3KQ9RT") == "AB3KQ9RT")
    }
    @Test func aLowercasedLinkIsNormalized() {
        #expect(JoinCodePaste.extract("aura://join?code=ab3kq9rt") == "AB3KQ9RT")
    }
    @Test func surroundingWhitespaceIsTolerated() {
        #expect(JoinCodePaste.extract("  aura://join?code=AB3KQ9RT\n") == "AB3KQ9RT")
    }
    @Test func aBareCodePassesThrough() {
        #expect(JoinCodePaste.extract("AB3KQ9RT") == "AB3KQ9RT")
    }
    @Test func arbitraryTextPassesThroughForDownstreamSanitizing() {
        #expect(JoinCodePaste.extract("see you at 9, code is AB3KQ9RT") == "see you at 9, code is AB3KQ9RT")
    }
    @Test func aNonJoinAuraLinkPassesThrough() {
        #expect(JoinCodePaste.extract("aura://history") == "aura://history")
    }
}
