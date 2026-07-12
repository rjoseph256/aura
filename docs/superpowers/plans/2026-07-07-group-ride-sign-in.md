# Group-ride Sign in with Apple Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire Sign in with Apple into the app so a rider can authenticate and complete a group ride, with an inline gate at the group-ride entry points and an Account section in Settings.

**Architecture:** A new `@Observable @MainActor` `AuthStore` (AuraKit) is the single source of truth for auth state, reading the cached session synchronously on init and observing an auth-event stream. It composes two seams: `AppleAuthenticating` (native Apple token) and the extended `GroupRideBackend` (Supabase session ops). Group-ride entry points route through `AppRouter.startGroupRide(_:)`, which pushes when signed in or presents Sign in with Apple (driven by `ASAuthorizationController` over the key window) and resumes the pending intent on success. Settings gains an Account section.

**Tech Stack:** Swift 6, SwiftUI, `@Observable`, AuthenticationServices, supabase-swift v2.50.0, Swift Testing.

## Global Constraints

- All unit-testable logic lives in **AuraKit/AuraCore** (Swift Testing, `AuraKitTests`/`AuraCoreTests`). The **app target has no unit-test bundle** — app-target files (`AppleSignInController`, `SupabaseGroupRideBackend`, `AppRouter`, `SettingsView`, `AuraApp`, `RootView`) are verified by build + on-device, never by unit tests.
- AuraKit/AuraCore must build on **macOS** (CI runs `swift test` on a mac host): no `import AuthenticationServices`, no `import UIKit`, no `import Supabase` in those modules. Those imports are app-target only.
- Solo riding stays account-free: nothing in the solo path calls `AuthStore`.
- One Supabase client only: app-target auth code reads `SupabaseClientProvider.shared`.
- supabase-swift is pinned to `majorVersion: 2` (resolved 2.50.0). `client.auth.authStateChanges` is `AsyncStream<(AuthChangeEvent, Session?)>`; `client.auth.currentSession` is a synchronous `Session?` (Keychain-backed).
- Crew display-name UserDefaults key is `DisplayNameStore.crewDisplayNameKey` ("crewDisplayName") — the single source of truth; never hardcode the literal.
- Cancel of the Apple sheet is a silent no-op (no error banner).
- Copy runs through natural, non-AI-tell phrasing.

---

### Task 1: `AppleAuthenticating` seam + fix the presentation anchor

Extracts a testable seam for the native Apple flow and fixes the device-breaking anchor.

**Files:**
- Create: `AuraCore/Sources/AuraKit/Auth/AppleAuthenticating.swift`
- Modify: `Aura/Sources/Auth/AppleSignInController.swift` (conform to the seam; fix `presentationAnchor`)
- Test: `AuraCore/Tests/AuraKitTests/Auth/AppleAuthenticatingTests.swift`

**Interfaces:**
- Produces: `AppleCredential { let idToken: String; let rawNonce: String; let fullName: String? }`; `enum AppleAuthError: Error, Equatable, Sendable { case canceled, failed }`; `protocol AppleAuthenticating: Sendable { func signIn() async throws -> AppleCredential }`.

- [ ] **Step 1: Write the failing test** (a fake conforms and returns a credential)

```swift
import Testing
@testable import AuraKit

struct AppleAuthenticatingTests {
    struct FakeApple: AppleAuthenticating {
        let result: Result<AppleCredential, AppleAuthError>
        func signIn() async throws -> AppleCredential { try result.get() }
    }

    @Test func returnsCredential() async throws {
        let fake = FakeApple(result: .success(AppleCredential(idToken: "tok", rawNonce: "nonce", fullName: "Rohun")))
        let cred = try await fake.signIn()
        #expect(cred.idToken == "tok")
        #expect(cred.rawNonce == "nonce")
        #expect(cred.fullName == "Rohun")
    }

    @Test func propagatesCanceled() async {
        let fake = FakeApple(result: .failure(.canceled))
        await #expect(throws: AppleAuthError.canceled) { try await fake.signIn() }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter AppleAuthenticatingTests`
Expected: FAIL — `AppleAuthenticating` / `AppleCredential` undefined.

- [ ] **Step 3: Create the seam**

```swift
// AuraCore/Sources/AuraKit/Auth/AppleAuthenticating.swift
import Foundation

/// The native Apple identity token + the RAW nonce (Apple received sha256(rawNonce)),
/// plus the full name Apple returns only on the first authorization.
public struct AppleCredential: Sendable, Equatable {
    public let idToken: String
    public let rawNonce: String
    public let fullName: String?
    public init(idToken: String, rawNonce: String, fullName: String?) {
        self.idToken = idToken; self.rawNonce = rawNonce; self.fullName = fullName
    }
}

/// AuraKit-side error so `AuthStore` can distinguish a user cancel (silent) from a
/// real failure without importing AuthenticationServices. The app-target adapter maps
/// `ASAuthorizationError.canceled` -> `.canceled`, everything else -> `.failed`.
public enum AppleAuthError: Error, Equatable, Sendable { case canceled, failed }

/// Seam over the native Sign in with Apple flow. The live conformer
/// (`AppleSignInController`) lives in the app target; tests inject a fake.
public protocol AppleAuthenticating: Sendable {
    func signIn() async throws -> AppleCredential
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter AppleAuthenticatingTests`
Expected: PASS.

- [ ] **Step 5: Conform `AppleSignInController` and fix the anchor**

```swift
// Aura/Sources/Auth/AppleSignInController.swift
import AuthenticationServices
import CryptoKit
import Foundation
import UIKit
import AuraKit

@MainActor
final class AppleSignInController: NSObject, AppleAuthenticating,
                                   ASAuthorizationControllerDelegate,
                                   ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<AppleCredential, Error>?
    private var currentRawNonce: String = ""

    func signIn() async throws -> AppleCredential {
        let rawNonce = Self.randomNonceString()
        currentRawNonce = rawNonce
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName]
        request.nonce = Self.sha256(rawNonce)
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization auth: ASAuthorization) {
        guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            continuation?.resume(throwing: AppleAuthError.failed)
            continuation = nil
            return
        }
        let name = [cred.fullName?.givenName, cred.fullName?.familyName]
            .compactMap { $0 }.joined(separator: " ")
        continuation?.resume(returning: AppleCredential(idToken: token, rawNonce: currentRawNonce,
                                                        fullName: name.isEmpty ? nil : name))
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        let mapped: AppleAuthError =
            (error as? ASAuthorizationError)?.code == .canceled ? .canceled : .failed
        continuation?.resume(throwing: mapped)
        continuation = nil
    }

    // Real device requires the app's key window, not a bare ASPresentationAnchor().
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
    }

    private static func randomNonceString(length: Int = 32) -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""; var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            _ = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            if random < UInt8(chars.count) { result.append(chars[Int(random)]); remaining -= 1 }
        }
        return result
    }
    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraKit/Auth/AppleAuthenticating.swift AuraCore/Tests/AuraKitTests/Auth/AppleAuthenticatingTests.swift Aura/Sources/Auth/AppleSignInController.swift
git commit -m "feat(auth): AppleAuthenticating seam + device-safe presentation anchor"
```

---

### Task 2: Extend `GroupRideBackend` with the auth-state seam

Adds the session-state surface `AuthStore` needs, on the existing backend seam + its two conformers.

**Files:**
- Modify: `AuraCore/Sources/AuraKit/GroupRide/GroupRideBackend.swift` (protocol + `AuthChange`)
- Modify: `AuraCore/Sources/AuraKit/GroupRide/InMemoryGroupRideBackend.swift`
- Modify: `Aura/Sources/Sync/SupabaseGroupRideBackend.swift`
- Test: `AuraCore/Tests/AuraKitTests/GroupRide/InMemoryGroupRideBackendAuthTests.swift`

**Interfaces:**
- Produces: `enum AuthChange: Sendable, Equatable { case signedIn(UUID), signedOut }`; on `GroupRideBackend`: `nonisolated var cachedUserID: UUID? { get }`, `func authEvents() -> AsyncStream<AuthChange>`, `func signOut() async throws`. `deleteAccount()` unchanged in signature (Supabase impl also invokes the edge function).
- Consumes: existing `InMemoryGroupRideBackend` sign-in behavior.

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter InMemoryGroupRideBackendAuthTests`
Expected: FAIL — `cachedUserID` / `authEvents` / `signOut` undefined.

- [ ] **Step 3: Extend the protocol**

Add to `GroupRideBackend.swift` (after the `GroupRideError` enum, and inside the protocol):

```swift
/// A change in the backend's authenticated session, observed by `AuthStore`.
public enum AuthChange: Sendable, Equatable { case signedIn(UUID), signedOut }
```

Add these three requirements to `protocol GroupRideBackend`:

```swift
    /// Synchronous read of the current session's user id (Keychain-backed on the live
    /// conformer), for correct auth state on a cold launch without a network round trip.
    nonisolated var cachedUserID: UUID? { get }
    /// A stream of session changes for the store's lifetime.
    func authEvents() -> AsyncStream<AuthChange>
    /// Clears the authenticated session.
    func signOut() async throws
```

- [ ] **Step 4: Implement on `InMemoryGroupRideBackend`**

Add stored state + methods (adapt to the fake's existing structure — it tracks a current user):

```swift
    // Auth-state seam (added Task 2).
    private var authContinuations: [UUID: AsyncStream<AuthChange>.Continuation] = [:]
    public nonisolated var cachedUserID: UUID? { currentUserIDValue }   // wire to the fake's existing signed-in id

    public func authEvents() -> AsyncStream<AuthChange> {
        AsyncStream { continuation in
            let key = UUID()
            authContinuations[key] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.authContinuations[key] = nil }
            }
        }
    }
    public func signOut() async throws {
        currentUserIDValue = nil
        for c in authContinuations.values { c.yield(.signedOut) }
    }
    private func emitSignedIn(_ id: UUID) { for c in authContinuations.values { c.yield(.signedIn(id)) } }
```

In the fake's existing `signIn(...)`, after it sets the signed-in user id, call `emitSignedIn(id)`. If the fake is an `actor`/`@MainActor` class, keep `cachedUserID` reading the same backing field. (Match the existing fake's isolation; if it stores the id under a different name, wire `cachedUserID`/`emitSignedIn` to that field.)

- [ ] **Step 5: Implement on `SupabaseGroupRideBackend`**

```swift
    public nonisolated var cachedUserID: UUID? { client.auth.currentSession?.user.id }

    public nonisolated func authEvents() -> AsyncStream<AuthChange> {
        AsyncStream { continuation in
            let task = Task {
                for await (event, session) in client.auth.authStateChanges {
                    switch event {
                    case .signedIn, .tokenRefreshed, .initialSession:
                        if let id = session?.user.id { continuation.yield(.signedIn(id)) }
                        else { continuation.yield(.signedOut) }
                    case .signedOut, .userDeleted:
                        continuation.yield(.signedOut)
                    default: break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public nonisolated func signOut() async throws { try await client.auth.signOut() }
```

Extend `deleteAccount()` to also invoke the edge function after the RPC:

```swift
    public nonisolated func deleteAccount() async throws {
        _ = try await client.rpc("delete_account").execute()
        _ = try await client.functions.invoke("delete-account")
    }
```

- [ ] **Step 6: Run tests**

Run: `cd AuraCore && swift test --filter InMemoryGroupRideBackendAuthTests`
Expected: PASS. Then full suite: `cd AuraCore && swift test` — Expected: PASS (no regressions).

- [ ] **Step 7: Commit**

```bash
git add AuraCore/Sources/AuraKit/GroupRide/GroupRideBackend.swift AuraCore/Sources/AuraKit/GroupRide/InMemoryGroupRideBackend.swift AuraCore/Tests/AuraKitTests/GroupRide/InMemoryGroupRideBackendAuthTests.swift Aura/Sources/Sync/SupabaseGroupRideBackend.swift
git commit -m "feat(auth): auth-state seam (cachedUserID, authEvents, signOut) + edge-fn delete"
```

---

### Task 3: `AuthStore` — init, cold-launch read, event observation

**Files:**
- Create: `AuraCore/Sources/AuraKit/Auth/AuthStore.swift`
- Test: `AuraCore/Tests/AuraKitTests/Auth/AuthStoreTests.swift`

**Interfaces:**
- Consumes: `GroupRideBackend` (incl. Task 2 additions), `AppleAuthenticating`.
- Produces: `@Observable @MainActor final class AuthStore` with `enum Status: Equatable, Sendable { case idle, signingIn, error(String) }`, `var userID: UUID? { get }`, `var isSignedIn: Bool { userID != nil }`, `var status: Status { get }`, `init(backend:apple:defaults:)`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AuraKit

@MainActor struct AuthStoreTests {
    private func store(_ b: InMemoryGroupRideBackend,
                       _ apple: AppleAuthenticating = FakeApple(.success(AppleCredential(idToken: "t", rawNonce: "n", fullName: "Rohun"))),
                       defaults: UserDefaults) -> AuthStore {
        AuthStore(backend: b, apple: apple, defaults: defaults)
    }
    struct FakeApple: AppleAuthenticating {
        let r: Result<AppleCredential, AppleAuthError>
        init(_ r: Result<AppleCredential, AppleAuthError>) { self.r = r }
        func signIn() async throws -> AppleCredential { try r.get() }
    }

    @Test func coldLaunchReadsCachedSession() async throws {
        let b = InMemoryGroupRideBackend()
        try await b.signIn(idToken: "t", nonce: "n", displayName: nil)   // pre-existing session
        let d = UserDefaults(suiteName: "auth.cold.\(UUID())")!
        let s = AuthStore(backend: b, apple: FakeApple(.success(.init(idToken: "t", rawNonce: "n", fullName: nil))), defaults: d)
        #expect(s.isSignedIn == true)
        #expect(s.userID == b.cachedUserID)
    }

    @Test func startsSignedOutWhenNoSession() async {
        let d = UserDefaults(suiteName: "auth.out.\(UUID())")!
        let s = AuthStore(backend: InMemoryGroupRideBackend(),
                          apple: FakeApple(.success(.init(idToken: "t", rawNonce: "n", fullName: nil))), defaults: d)
        #expect(s.isSignedIn == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter AuthStoreTests`
Expected: FAIL — `AuthStore` undefined.

- [ ] **Step 3: Implement init + observation**

```swift
// AuraCore/Sources/AuraKit/Auth/AuthStore.swift
import Foundation
import Observation
import AuraCore

@Observable
@MainActor
public final class AuthStore {
    public enum Status: Equatable, Sendable { case idle, signingIn, error(String) }

    public private(set) var userID: UUID?
    public var isSignedIn: Bool { userID != nil }
    public private(set) var status: Status = .idle

    @ObservationIgnored private let backend: any GroupRideBackend
    @ObservationIgnored private let apple: any AppleAuthenticating
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    static let lastUserIDKey = "auth.lastSignedInUserID"

    public init(backend: any GroupRideBackend, apple: any AppleAuthenticating,
                defaults: UserDefaults = .standard) {
        self.backend = backend
        self.apple = apple
        self.defaults = defaults
        self.userID = backend.cachedUserID    // synchronous cold-launch read (Keychain)
        eventTask = Task { [weak self] in
            guard let events = self?.backend.authEvents() else { return }
            for await change in events {
                guard let self else { return }
                switch change {
                case .signedIn(let id): self.userID = id
                case .signedOut: self.userID = nil
                }
            }
        }
    }

    deinit { eventTask?.cancel() }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter AuthStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Auth/AuthStore.swift AuraCore/Tests/AuraKitTests/Auth/AuthStoreTests.swift
git commit -m "feat(auth): AuthStore init with cold-launch session read + event observation"
```

---

### Task 4: `AuthStore.signInWithApple()` — compose, seed name, account-switch, cancel

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Auth/AuthStore.swift`
- Test: `AuraCore/Tests/AuraKitTests/Auth/AuthStoreSignInTests.swift`

**Interfaces:**
- Produces: `func signInWithApple() async`. On success sets `userID` and (best-effort) the crew name; on `AppleAuthError.canceled` returns to `.idle` silently; on other failure sets `.error(...)`.
- Consumes: `DisplayNameStore.crewDisplayNameKey`, `DisplayName.normalized`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import AuraKit

@MainActor struct AuthStoreSignInTests {
    struct FakeApple: AppleAuthenticating {
        let r: Result<AppleCredential, AppleAuthError>
        func signIn() async throws -> AppleCredential { try r.get() }
    }
    private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "auth.signin.\(UUID())")! }

    @Test func signsInAndSeedsCrewNameFromApple() async {
        let b = InMemoryGroupRideBackend(); let d = freshDefaults()
        let s = AuthStore(backend: b, apple: FakeApple(r: .success(.init(idToken: "t", rawNonce: "n", fullName: "Rohun"))), defaults: d)
        await s.signInWithApple()
        #expect(s.isSignedIn == true)
        #expect(s.status == .idle)
        #expect(d.string(forKey: DisplayNameStore.crewDisplayNameKey) == "Rohun")
    }

    @Test func noNameFromAppleLeavesCrewNameForTheGate() async {
        let b = InMemoryGroupRideBackend(); let d = freshDefaults()
        let s = AuthStore(backend: b, apple: FakeApple(r: .success(.init(idToken: "t", rawNonce: "n", fullName: nil))), defaults: d)
        await s.signInWithApple()
        #expect(s.isSignedIn == true)
        #expect(d.string(forKey: DisplayNameStore.crewDisplayNameKey) == nil)
    }

    @Test func cancelIsSilent() async {
        let b = InMemoryGroupRideBackend(); let d = freshDefaults()
        let s = AuthStore(backend: b, apple: FakeApple(r: .failure(.canceled)), defaults: d)
        await s.signInWithApple()
        #expect(s.isSignedIn == false)
        #expect(s.status == .idle)
    }

    @Test func failureSetsError() async {
        let b = InMemoryGroupRideBackend(); let d = freshDefaults()
        let s = AuthStore(backend: b, apple: FakeApple(r: .failure(.failed)), defaults: d)
        await s.signInWithApple()
        #expect(s.isSignedIn == false)
        if case .error = s.status {} else { Issue.record("expected .error, got \(s.status)") }
    }

    @Test func differentUserClearsStaleCrewName() async {
        let b = InMemoryGroupRideBackend(); let d = freshDefaults()
        d.set("Alice", forKey: DisplayNameStore.crewDisplayNameKey)          // leftover from a prior user
        d.set(UUID().uuidString, forKey: AuthStore.lastUserIDKey)            // a DIFFERENT prior user
        let s = AuthStore(backend: b, apple: FakeApple(r: .success(.init(idToken: "t", rawNonce: "n", fullName: nil))), defaults: d)
        await s.signInWithApple()
        #expect(d.string(forKey: DisplayNameStore.crewDisplayNameKey) == nil) // stale name cleared
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd AuraCore && swift test --filter AuthStoreSignInTests`
Expected: FAIL — `signInWithApple` undefined.

- [ ] **Step 3: Implement**

Add to `AuthStore`:

```swift
    public func signInWithApple() async {
        status = .signingIn
        do {
            let cred = try await apple.signIn()
            // Authenticate (auth only — name push is best-effort below so a name
            // failure never fails sign-in).
            try await backend.signIn(idToken: cred.idToken, nonce: cred.rawNonce, displayName: nil)
            let uid = try await backend.currentUserID()

            // Account switch: don't let a prior user's local crew name bleed into a
            // different Apple ID. If we can't seed a fresh name from Apple, clear it so
            // the (now working) name screen prompts instead.
            let previous = defaults.string(forKey: Self.lastUserIDKey)
            if previous != uid.uuidString, cred.fullName == nil {
                defaults.removeObject(forKey: DisplayNameStore.crewDisplayNameKey)
            }
            if let name = cred.fullName, let normalized = DisplayName.normalized(name) {
                try? await backend.renameDisplayName(normalized)             // best-effort
                defaults.set(normalized, forKey: DisplayNameStore.crewDisplayNameKey)
            }
            defaults.set(uid.uuidString, forKey: Self.lastUserIDKey)
            userID = uid
            status = .idle
        } catch AppleAuthError.canceled {
            status = .idle
        } catch {
            status = .error("Couldn't sign in — check your connection and try again.")
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd AuraCore && swift test --filter AuthStoreSignInTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Auth/AuthStore.swift AuraCore/Tests/AuraKitTests/Auth/AuthStoreSignInTests.swift
git commit -m "feat(auth): AuthStore.signInWithApple with best-effort name seed + account-switch guard"
```

---

### Task 5: `AuthStore.signOut()` and `deleteAccount()`

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Auth/AuthStore.swift`
- Test: `AuraCore/Tests/AuraKitTests/Auth/AuthStoreSessionTests.swift`

**Interfaces:**
- Produces: `func signOut() async`, `func deleteAccount() async`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import AuraKit

@MainActor struct AuthStoreSessionTests {
    struct FakeApple: AppleAuthenticating {
        func signIn() async throws -> AppleCredential { .init(idToken: "t", rawNonce: "n", fullName: "Rohun") }
    }
    @Test func signOutClearsSessionKeepsCrewName() async {
        let b = InMemoryGroupRideBackend(); let d = UserDefaults(suiteName: "auth.so.\(UUID())")!
        let s = AuthStore(backend: b, apple: FakeApple(), defaults: d)
        await s.signInWithApple()
        #expect(s.isSignedIn == true)
        await s.signOut()
        #expect(s.isSignedIn == false)
        #expect(d.string(forKey: DisplayNameStore.crewDisplayNameKey) == "Rohun")  // kept for same-user re-sign-in
    }
    @Test func deleteAccountClearsSessionAndCrewName() async {
        let b = InMemoryGroupRideBackend(); let d = UserDefaults(suiteName: "auth.da.\(UUID())")!
        let s = AuthStore(backend: b, apple: FakeApple(), defaults: d)
        await s.signInWithApple()
        await s.deleteAccount()
        #expect(s.isSignedIn == false)
        #expect(d.string(forKey: DisplayNameStore.crewDisplayNameKey) == nil)
        #expect(d.string(forKey: AuthStore.lastUserIDKey) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd AuraCore && swift test --filter AuthStoreSessionTests`
Expected: FAIL — `signOut` / `deleteAccount` undefined.

- [ ] **Step 3: Implement**

```swift
    public func signOut() async {
        try? await backend.signOut()
        userID = nil                       // authEvents will also confirm this
    }

    public func deleteAccount() async {
        do {
            try await backend.deleteAccount()
            try? await backend.signOut()
            defaults.removeObject(forKey: DisplayNameStore.crewDisplayNameKey)
            defaults.removeObject(forKey: Self.lastUserIDKey)
            userID = nil
            status = .idle
        } catch {
            status = .error("Couldn't delete your account — try again.")
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd AuraCore && swift test --filter AuthStoreSessionTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Auth/AuthStore.swift AuraCore/Tests/AuraKitTests/Auth/AuthStoreSessionTests.swift
git commit -m "feat(auth): AuthStore signOut + deleteAccount"
```

---

### Task 6: `DisplayNameStore.save()` ordering fix

Backend push first, local mirror only on success (so a failed save can't leave a phantom name).

**Files:**
- Modify: `Aura/Sources/GroupRide/DisplayNameStore.swift:47-54`
- Test: `AuraCore/Tests/AuraKitTests/GroupRide/DisplayNameStoreSaveTests.swift`

Note: `DisplayNameStore` is in the app target but has no `AuthenticationServices`/`Supabase`/`UIKit` imports — verify it compiles into AuraKitTests via `@testable import`. If it does not (app-target-only), move the ordering assertion into a new small AuraKit type test that mirrors the same sequence; otherwise test it directly. Confirm by attempting the test first.

**Interfaces:**
- Consumes: `GroupRideBackend.renameDisplayName`.

- [ ] **Step 1: Write the failing test** (a backend that throws must NOT leave a local name)

```swift
import Testing
import Foundation
@testable import AuraKit

@MainActor struct DisplayNameStoreSaveTests {
    final class ThrowingRename: InMemoryGroupRideBackend { }   // subclass/override renameDisplayName to throw — or a small stub conforming to GroupRideBackend

    @Test func failedBackendLeavesNoLocalName() async {
        let d = UserDefaults(suiteName: "dn.save.\(UUID())")!
        let backend = FailingRenameBackend()                  // conforms to GroupRideBackend; renameDisplayName throws
        let store = DisplayNameStore(defaults: d, backend: backend)
        store.name = "Rohun"
        try? await store.save()
        #expect(d.string(forKey: DisplayNameStore.crewDisplayNameKey) == nil)  // not mirrored on failure
    }
}
```

(Implement `FailingRenameBackend` as a minimal `GroupRideBackend` conformer whose `renameDisplayName` throws and other methods no-op; place it in the test file.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter DisplayNameStoreSaveTests`
Expected: FAIL — local name is set before the throwing backend call (current code order).

- [ ] **Step 3: Reorder `save()`**

```swift
    public func save() async throws {
        guard let normalized = DisplayName.normalized(name) else {
            throw DisplayNameError.invalid
        }
        try await backend.renameDisplayName(normalized)               // backend first
        name = normalized
        defaults.set(normalized, forKey: DisplayNameStore.crewDisplayNameKey)  // mirror only on success
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter DisplayNameStoreSaveTests`
Expected: PASS. Full suite: `cd AuraCore && swift test` — PASS.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/GroupRide/DisplayNameStore.swift AuraCore/Tests/AuraKitTests/GroupRide/DisplayNameStoreSaveTests.swift
git commit -m "fix(group): save crew name to backend before mirroring locally"
```

---

### Task 7: `AppRouter` gate — `startGroupRide`, pending intent, resume, reentrancy

App-target wiring (no unit-test bundle). Verified by build + the AuraKit tests above + device.

**Files:**
- Modify: `Aura/Sources/App/AppRouter.swift`

**Interfaces:**
- Produces: `func startGroupRide(_ entry: GroupRideEntry, isSignedIn: Bool)`, `var pendingSignIn: GroupRideEntry? { get }`, `func resumePendingGroupRide()`, `func cancelPendingGroupRide()`.

- [ ] **Step 1: Add the gate to AppRouter**

```swift
    /// Non-nil while the sign-in sheet is up for a deferred group action. Held here (not in
    /// a view) so the pending intent survives view teardown and the deep-link round trip.
    private(set) var pendingSignIn: GroupRideEntry?

    /// Entry point for every group-ride action. Pushes immediately when signed in; otherwise
    /// stashes the intent and lets RootView drive sign-in. Reentrant-safe: a second call while
    /// one is pending is ignored.
    func startGroupRide(_ entry: GroupRideEntry, isSignedIn: Bool) {
        if isSignedIn {
            push(.groupRide(entry))
        } else if pendingSignIn == nil {
            pendingSignIn = entry
        }
    }
    /// Called by RootView after a successful sign-in.
    func resumePendingGroupRide() {
        guard let entry = pendingSignIn else { return }
        pendingSignIn = nil
        push(.groupRide(entry))
    }
    func cancelPendingGroupRide() { pendingSignIn = nil }
```

Update `handle(url:)` so a deep-link join goes through the gate. Since `handle` doesn't know auth state, route group entries into `pendingSignIn`-or-push by exposing auth through the call site: change `handle(url:)` to accept `isSignedIn`:

```swift
    func handle(url: URL, isSignedIn: Bool) {
        guard !isRideActive, let link = DeepLink.parse(url) else { return }
        if case let .preview(place) = link { remember(place) }
        if case let .join(code) = link {
            startGroupRide(.join(code), isSignedIn: isSignedIn)
            return
        }
        path = AppRoute.stack(for: link)
    }
```

- [ ] **Step 2: Build to verify it compiles**

Delegate to the builder: build the `Aura` scheme for the device. Expected: BUILD SUCCESS (call sites updated in Task 8; if `handle(url:)` callers break, fix them in Task 8).

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/App/AppRouter.swift
git commit -m "feat(group): AppRouter group-ride auth gate (pending intent + resume + reentrancy)"
```

---

### Task 8: Wire entry points + RootView sign-in presentation

**Files:**
- Modify: `Aura/Sources/Plan/RoutePreviewView.swift` ("Ride together")
- Modify: `Aura/Sources/GroupRide/GroupRideJoinView.swift` (join push)
- Modify: `Aura/Sources/AuraApp.swift` (`RootView`: present sign-in when `router.pendingSignIn != nil`; `.onOpenURL`)
- Modify: `Aura/Sources/GroupRide/GroupRideFlowView.swift` (createFailed copy tidy)

**Interfaces:**
- Consumes: `AuthStore` from the environment (injected in Task 9), `AppRouter.startGroupRide/resumePendingGroupRide/cancelPendingGroupRide`.

- [ ] **Step 1: Route the entry points through the gate**

`RoutePreviewView` "Ride together":
```swift
    @Environment(AuthStore.self) private var auth
    // ...
    Button("Ride together") {
        if let selected { router.startGroupRide(.create(selected), isSignedIn: auth.isSignedIn) }
    }
```

`GroupRideJoinView` join action — replace `router.push(.groupRide(.join(joinCode)))` with:
```swift
    router.startGroupRide(.join(joinCode), isSignedIn: auth.isSignedIn)
```
(add `@Environment(AuthStore.self) private var auth`).

`AuraApp` `.onOpenURL`:
```swift
    .onOpenURL { router.handle(url: $0, isSignedIn: auth.isSignedIn) }
```
(RootView reads `@Environment(AuthStore.self) private var auth`).

- [ ] **Step 2: Present sign-in from RootView**

Drive the Apple flow when a group action is pending, then resume:
```swift
    // In RootView.body, on the NavigationStack:
    .task(id: router.pendingSignIn) {
        guard router.pendingSignIn != nil else { return }
        await auth.signInWithApple()
        if auth.isSignedIn { router.resumePendingGroupRide() }
        else { router.cancelPendingGroupRide() }   // cancel or failure: drop the intent, stay put
    }
```
(The Apple system UI is presented by `AppleSignInController` over the key window — no SwiftUI sheet. `auth.status == .error` surfaces via Settings / a lightweight banner; a mid-gate error simply leaves the user where they were.)

- [ ] **Step 3: Tidy `createFailed` copy**

In `GroupRideFlowView`, change the `.createFailed` message from "This route is too detailed to share as a group ride." to a generic, accurate line:
```swift
        case .createFailed:
            dismissMessage(title: "Couldn't start the group ride — try again.",
                           systemImage: "exclamationmark.triangle")
```

- [ ] **Step 4: Build**

Delegate to the builder: build `Aura` for the device. Expected: BUILD SUCCESS. (Requires Task 9's `AuthStore` in the environment to resolve `@Environment(AuthStore.self)` — do Task 9 first or together; if building standalone, expect an unresolved-environment runtime trap, not a compile error.)

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Plan/RoutePreviewView.swift Aura/Sources/GroupRide/GroupRideJoinView.swift Aura/Sources/AuraApp.swift Aura/Sources/GroupRide/GroupRideFlowView.swift
git commit -m "feat(group): route group entry points through the sign-in gate"
```

---

### Task 9: Inject `AuthStore` into `AuraApp`

**Files:**
- Modify: `Aura/Sources/AuraApp.swift`
- Modify: `Aura/Sources/Sync/SupabaseClientProvider.swift` (opt into local-session-as-initial for offline cold-launch correctness)

- [ ] **Step 1: Construct + inject the store**

```swift
    @State private var auth = AuthStore(backend: SupabaseGroupRideBackend(),
                                        apple: AppleSignInController())
    // ...
    RootView()
        // ...existing .environment(...) lines...
        .environment(auth)
```

- [ ] **Step 2: Ensure session persistence + offline initial session**

In `SupabaseClientProvider.shared`, pass options so the stored Keychain session is emitted as the initial session even offline:
```swift
    public nonisolated static let shared = SupabaseClient(
        supabaseURL: URL(string: "https://wyofhmufnttiqyjkrbxi.supabase.co")!,
        supabaseKey: "sb_publishable_JszmSwhSo_MEC8yue7Z76A_QYwVo84h",
        options: SupabaseClientOptions(
            auth: SupabaseClientOptions.AuthOptions(emitLocalSessionAsInitialSession: true)))
```
(Verify the exact option label against supabase-swift 2.50.0 `AuthClient.Configuration`; if the label differs, use the resolved name. `AuthStore.init` already reads `cachedUserID` synchronously, so this only hardens the async stream's first event.)

- [ ] **Step 3: Build**

Delegate to the builder: build `Aura` for the device. Expected: BUILD SUCCESS.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/AuraApp.swift Aura/Sources/Sync/SupabaseClientProvider.swift
git commit -m "feat(auth): inject AuthStore + persist/emit local session on cold launch"
```

---

### Task 10: Settings Account section

**Files:**
- Modify: `Aura/Sources/Settings/SettingsView.swift`

- [ ] **Step 1: Add the Account section**

Add `@Environment(AuthStore.self) private var auth`, `@Environment(AppRouter.self) private var router`, and `@State private var confirmingDelete = false`. Insert a section (native Apple button when signed out; account rows when signed in):

```swift
    Section("Account") {
        if auth.isSignedIn {
            NavigationLink { DisplayNameEditor(store: displayNameStore) }
                label: { linkLabel(icon: "person.crop.circle.fill", tint: AuraTheme.accent, title: "Crew name") }
            Button("Sign out") { Task { await auth.signOut() } }
                .disabled(router.isRideActive)
            Button("Delete account", role: .destructive) { confirmingDelete = true }
                .disabled(router.isRideActive)
        } else {
            SignInWithAppleButton(.signIn, onRequest: { _ in }, onCompletion: { _ in })
                .signInWithAppleButtonStyle(.white)
                .frame(height: 44)
                .allowsHitTesting(false)                 // the real flow is AuthStore's; overlay a tap target
                .overlay(Button("") { Task { await auth.signInWithApple() } }.opacity(0.01))
            Text("Sign in to ride with your crew.")
                .font(.footnote).foregroundStyle(AuraTheme.textSecondary)
        }
    }
    .listRowBackground(AuraTheme.surface)
    .alert("Delete account?", isPresented: $confirmingDelete) {
        Button("Delete", role: .destructive) { Task { await auth.deleteAccount() } }
        Button("Cancel", role: .cancel) {}
    } message: {
        Text("This removes your crew profile and any group-ride data on the server. Your ride history on this device is not affected.")
    }
```
Move the existing top-level "Crew name" link out of the "Ride" section (it now lives under Account for signed-in users). If `SignInWithAppleButton`'s own callbacks are preferred over the overlay, wire `onRequest`/`onCompletion` to bridge into `AuthStore` instead — but the app already owns the nonce/token flow in `AppleSignInController`, so triggering `auth.signInWithApple()` directly (as above) keeps one code path. Pick the overlay approach for a single flow.

- [ ] **Step 2: Build**

Delegate to the builder: build `Aura` for the device. Expected: BUILD SUCCESS.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Settings/SettingsView.swift
git commit -m "feat(settings): Account section — sign in / crew name / sign out / delete"
```

---

### Task 11: On-device verification

Not a code task — the acceptance gate. Requires the Supabase Apple provider + Apple Developer portal capability in place.

- [ ] **Step 1: Preconditions**
  - Supabase → Auth → Apple: enabled, Client IDs includes `com.rohunjoseph.aura`, "Allow users without an email" ON.
  - Apple Developer portal: `com.apple.developer.applesignin` capability enabled for the App ID.
  - `delete-account` edge function deployed.

- [ ] **Step 2: Build + install + launch on the device** (builder agent, `-destination id=<idb-UDID>`).

- [ ] **Step 3: Walk the flows on device** (record the crash-report baseline first via `idb crash list`):
  - Signed out → "Ride together" → Apple sheet presents over the route preview → complete sign-in → flows into the lobby (name seeded from Apple, no name screen). No new crash report.
  - Sign out in Settings → "Ride together" again → Apple sheet → cancel → returns to the route preview, no navigation, no error banner.
  - Deep link `aura://join?code=…` while signed out → Apple sheet → sign in → joins with the code intact.
  - Settings account section: crew name edit persists; delete-account removes server profile (verify via Supabase `execute_sql`) and signs out; local ride history still present in History.
  - Confirm Supabase logs (realtime/postgres via MCP) now show `create_ride` / auth activity — proving the path reaches the backend.

- [ ] **Step 4:** Report results; file any follow-ups.

---

## Self-Review

**Spec coverage:** AuthStore (T3–5), Apple seam + anchor fix (T1), auth-state seam incl. edge-fn delete (T2), inline gate at all three entry points with pending intent + reentrancy (T7–8), deep-link through the gate (T7–8), Settings account section incl. HIG button + delete confirmation + isRideActive guard (T10), crew-name seed + account-switch + save ordering (T4, T6), cold-launch + persistence (T3, T9), error handling incl. cancel-silent and createFailed copy (T4, T8), device-only verification + external deps (T11). All spec sections map to a task.

**Placeholder scan:** No TBD/TODO. Two honest verification caveats remain (the in-memory fake's internal field name in T2; the exact `emitLocalSessionAsInitialSession` label in T9) — both instruct the implementer to confirm against the resolved source, with the fallback stated.

**Type consistency:** `AppleCredential`/`AppleAuthError`/`AppleAuthenticating` (T1) used verbatim in T3–5. `AuthChange`/`cachedUserID`/`authEvents`/`signOut` (T2) used in T3. `AuthStore.Status`/`userID`/`isSignedIn`/`signInWithApple`/`signOut`/`deleteAccount`/`lastUserIDKey` consistent across T3–5, T8, T10. `startGroupRide`/`pendingSignIn`/`resumePendingGroupRide`/`cancelPendingGroupRide` consistent T7–8. `DisplayNameStore.crewDisplayNameKey` used, never the literal.

---

## Plan review reconciliation (adversarial plan review, 2026-07-07)

Two independent refuting reviewers (API-correctness vs. resolved supabase-swift 2.50.0, and plan-integrity/build-order) ran against the plan. These corrections are binding and supersede the task bodies where they conflict.

### C1 — Build order: no signature-threading, no broken commits (Findings 1, 2)

Do **not** change `AppRouter.handle(url:)`'s signature or thread `isSignedIn` through call sites (that would land a non-building commit and invert the 8/9 dependency). Instead, inject a closure into `AppRouter`:

```swift
// AppRouter (Task 7): read auth via an injected closure, set once at app init.
var checkSignedIn: () -> Bool = { false }
private(set) var pendingSignIn: GroupRideEntry?

func startGroupRide(_ entry: GroupRideEntry) {
    if checkSignedIn() { push(.groupRide(entry)) }
    else if pendingSignIn == nil { pendingSignIn = entry }
}
func resumePendingGroupRide() { guard let e = pendingSignIn else { return }; pendingSignIn = nil; push(.groupRide(e)) }
func cancelPendingGroupRide() { pendingSignIn = nil }
```
`handle(url:)` keeps its signature and routes a `.join(code)` link via `startGroupRide(.join(code))`. Corrected task order: **Task 7 (AppRouter gate, closure-based — builds green, methods unused yet) → Task 9 (construct AuthStore, set `router.checkSignedIn = { [weak auth] in auth?.isSignedIn ?? false }`, inject env) → Task 8 (wire RoutePreview/JoinView to `router.startGroupRide(entry)` + RootView sign-in driver)**. Call sites take no `isSignedIn` argument, so every commit builds.

### C2 — RootView sign-in driver: use onChange, not `.task(id:)` (Finding 6)

`.task(id: router.pendingSignIn)` re-fires on the nil→X→nil transitions and can race across attempts. Drive it once per stash with the reentrancy guard already preventing overwrites:

```swift
.onChange(of: router.pendingSignIn) { _, entry in
    guard entry != nil else { return }              // fires only on nil -> entry (guard blocks overwrite)
    Task {
        await auth.signInWithApple()
        if auth.isSignedIn { router.resumePendingGroupRide() } else { router.cancelPendingGroupRide() }
    }
}
```

### C3 — Move `DisplayNameStore` into AuraKit (Finding 3 / Defect 4)

`DisplayNameStore` lives in the **app target** (`Aura/Sources/GroupRide/`), so `AuraKitTests` cannot import it — Task 6's test is impossible as written. It imports only `Observation`/`AuraCore`/`AuraKit` (no UIKit/Supabase/AuthenticationServices), so **move the file to `AuraCore/Sources/AuraKit/GroupRide/DisplayNameStore.swift`** (add a leading step to Task 6; remove it from the app target's sources — xcodegen picks up AuraKit as a package product). Then the Task 6 test compiles as written. Update any app-target `import` if needed (it already `import AuraKit`).

### C4 — `InMemoryGroupRideBackend` is an `actor`; store the id + continuations in `Store` (Findings 4, 5 / Defect 5)

The fake is `public final actor` with a `nonisolated let store: Store` (`@unchecked Sendable`) and an actor-isolated `private var currentUser: UUID?`. A `nonisolated var cachedUserID` **cannot** read `currentUser`. Move the signed-in id (and the auth continuations) into `Store`:

```swift
final class Store: @unchecked Sendable {
    // ...existing...
    let lock = NSLock()
    var currentUserID: UUID?
    var authContinuations: [UUID: AsyncStream<AuthChange>.Continuation] = [:]
}
public nonisolated var cachedUserID: UUID? { store.lock.withLock { store.currentUserID } }
public nonisolated func authEvents() -> AsyncStream<AuthChange> {
    AsyncStream { cont in
        let key = UUID()
        store.lock.withLock { store.authContinuations[key] = cont }
        cont.onTermination = { [store] _ in store.lock.withLock { store.authContinuations[key] = nil } }
    }
}
public func signOut() async throws {
    store.lock.withLock { store.currentUserID = nil }
    emit(.signedOut)
}
private nonisolated func emit(_ c: AuthChange) {
    let conts = store.lock.withLock { Array(store.authContinuations.values) }
    for k in conts { k.yield(c) }
}
```
The existing `signIn(...)` sets `store.currentUserID = <id>` and calls `emit(.signedIn(id))`; `deleteAccount()` clears `store.currentUserID`. (Wire `currentUserID` to whatever id the fake already mints on sign-in — the field the current `currentUser` used.)

### C5 — `AuthStore.eventTask` must be `@MainActor` (Defect 7)

Mark the task so the `userID` mutations are on the main actor:
```swift
eventTask = Task { @MainActor [weak self] in
    guard let events = self?.backend.authEvents() else { return }
    for await change in events {
        guard let self else { return }
        switch change { case .signedIn(let id): self.userID = id; case .signedOut: self.userID = nil }
    }
}
```

### C6 — Drop the `SupabaseClientOptions` change in Task 9 (Defect 2)

`SupabaseClientOptions.AuthOptions(emitLocalSessionAsInitialSession:)` also requires a `storage:` argument and risks a non-compiling commit. It is unnecessary: `AuthStore.init` already reads `backend.cachedUserID` (→ `client.auth.currentSession`) synchronously, which is correct on an offline cold launch. **Remove Task 9 Step 2 entirely** (leave `SupabaseClientProvider` unchanged); the async `authEvents` stream only needs to deliver *subsequent* changes.

### C7 — Settings sign-in button: styled Button, not the overlay hack (Defect 6)

The app owns the Apple token flow (`AppleSignInController`), so a native `SignInWithAppleButton` would fire its own competing request. Render a themed button (Apple mark + "Sign in with Apple", per HIG sizing/contrast) that calls `auth.signInWithApple()` directly — no invisible overlay:
```swift
Button { Task { await auth.signInWithApple() } } label: {
    Label("Sign in with Apple", systemImage: "apple.logo")
        .frame(maxWidth: .infinity).frame(height: 44)
}
.buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
```

### C8 — Minor (Findings 9, 10)

- `.createFailed` new copy reuses `.routeUnavailable`'s icon — give `.createFailed` a distinct symbol (e.g. `person.2.slash`) so the two error surfaces aren't visually identical.
- Task 10 wording: **remove** the Crew name link from the "Ride" section and **add** it to the Account section (signed-in branch); construct `displayNameStore` inside that branch so it isn't built for signed-out users.
