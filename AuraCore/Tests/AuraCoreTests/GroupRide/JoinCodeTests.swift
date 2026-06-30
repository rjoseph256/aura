import Testing
@testable import AuraCore

struct JoinCodeTests {
    @Test func rejectsAmbiguousGlyphs() {
        #expect(JoinCode(rawValue: "ABCDEFOO") == nil)   // contains O
        #expect(JoinCode(rawValue: "ABCDEF11") == nil)   // contains 1
    }
    @Test func rejectsWrongLength() {
        #expect(JoinCode(rawValue: "ABCDEFG") == nil)    // 7
        #expect(JoinCode(rawValue: "ABCDEFGHJ") == nil)  // 9
    }
    @Test func acceptsValidCode() {
        #expect(JoinCode(rawValue: "ABCDEFGH")?.rawValue == "ABCDEFGH")
    }
    @Test func normalizesLowercase() {
        #expect(JoinCode(rawValue: "abcdefgh")?.rawValue == "ABCDEFGH")
    }
}
