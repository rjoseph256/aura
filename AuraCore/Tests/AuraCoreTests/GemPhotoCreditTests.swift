import Testing
import AuraCore

@Suite struct GemPhotoCreditTests {
    @Test func nilAndEmptyProduceNoCredit() {
        #expect(gemPhotoCredit(nil) == nil)
        #expect(gemPhotoCredit("") == nil)
        #expect(gemPhotoCredit("   ") == nil)
    }
    @Test func attributionBecomesCreditLine() {
        #expect(gemPhotoCredit("Jane Doe, CC BY-SA 4.0") == "Photo: Jane Doe, CC BY-SA 4.0")
    }
}
