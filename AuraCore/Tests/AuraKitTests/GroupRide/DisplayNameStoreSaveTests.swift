import Testing
import Foundation
@testable import AuraKit

@MainActor struct DisplayNameStoreSaveTests {
    @Test func failedBackendLeavesNoLocalName() async throws {
        let d = UserDefaults(suiteName: "dn.save.\(UUID())")!
        let backend = InMemoryGroupRideBackend()
        try await backend.signIn(idToken: "token", nonce: "nonce", displayName: nil)
        backend.store.forceRenameError = .notAuthenticated

        let store = DisplayNameStore(defaults: d, backend: backend)
        store.name = "Rohun"
        try? await store.save()

        #expect(d.string(forKey: DisplayNameStore.crewDisplayNameKey) == nil)
    }
}
