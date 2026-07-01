import Testing
import AuraCore

struct DisplayNameTests {
    @Test func trimsWhitespace() { #expect(DisplayName.normalized("  Mike  ") == "Mike") }
    @Test func emptyBecomesNil() {
        #expect(DisplayName.normalized("") == nil)
        #expect(DisplayName.normalized("   ") == nil)
    }
    @Test func capsAt40Graphemes() {
        let long = String(repeating: "a", count: 60)
        #expect(DisplayName.normalized(long)?.count == 40)
    }
    @Test func doesNotSplitGraphemeCluster() {
        // 40 flags (each a multi-scalar grapheme) must not be cut mid-cluster.
        let flags = String(repeating: "🇺🇸", count: 45)
        let n = DisplayName.normalized(flags)!
        #expect(n.count == 40)                      // 40 whole clusters
        #expect(n.unicodeScalars.count == 80)       // no half-flag tail
    }
    @Test func fallbackIsRiderNoPeriod() { #expect(DisplayName.forDisplay("   ") == "Rider") }
}
