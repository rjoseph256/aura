import Testing
import Foundation
@testable import AuraKit

struct InMemoryGroupRideBackendAuthTests {
    @Test func cachedUserIDReflectsSignInAndOut() async throws {
        let b = InMemoryGroupRideBackend()
        #expect(b.cachedUserID == nil)
        try await b.signIn(idToken: "t", nonce: "n", displayName: "Rohun")
        #expect(b.cachedUserID != nil)
        try await b.signOut()
        #expect(b.cachedUserID == nil)
    }

    @Test func authEventsEmitOnSignInAndOut() async throws {
        let b = InMemoryGroupRideBackend()
        var stream = b.authEvents().makeAsyncIterator()
        try await b.signIn(idToken: "t", nonce: "n", displayName: nil)
        let inEvent = await stream.next()
        #expect(inEvent == .signedIn(b.cachedUserID!))
        try await b.signOut()
        #expect(await stream.next() == .signedOut)
    }
}
