# Group-ride Sign in with Apple — design

Date: 2026-07-07
Status: approved (brainstorming), pending spec review

## Problem

Group rides require a Supabase-authenticated session: `create_ride`, `join_ride`,
`upsert_display_name`, and the roster/live RPCs all reject an anonymous caller
(`raise exception 'unauthorized'` when `auth.uid()` is null — migration
`0007_identity.sql`). But no Sign in with Apple flow is wired into the app.
`AppleSignInController.signIn()` and `SupabaseGroupRideBackend.signIn(...)` both
exist and work; nothing ever calls them. There is no account UI and no notion of
auth state anywhere in the app.

Consequence: a rider who taps "Ride together" (or "Join") with no session lands on
the "Crew name" screen and can't save the name — `upsert_display_name` rejects the
unauthenticated call — so group rides dead-end for everyone. (The hard crash on that
same screen, from a nested `NavigationStack`, was fixed separately in commit
`7c07ac6`; this spec builds on that fix.)

## Goals

- Wire Sign in with Apple so a rider can authenticate and complete a group ride.
- Keep solo riding fully account-free — auth is never in front of the solo path.
- Reuse the existing native + Supabase plumbing rather than rebuild auth.
- Make auth state observable so both the inline gate and Settings read one source.
- Seed the crew display name from Apple's name at first sign-in; fall back to the
  (now crash-free) name screen only when Apple returns no name — and only *after*
  authentication, so the name actually saves.

## Non-goals / out of scope

- Any auth provider other than Apple.
- Email/password, magic links, or collecting the rider's email (name scope only).
- Onboarding redesign or forcing sign-in at launch.
- Changing the group-ride live/transport layer.

## External dependencies (owner: Rohun, in Supabase / Apple)

These gate on-device verification, not the code:

1. **Supabase → Auth → Apple provider** enabled, configured for the **native** path:
   - **Client IDs** must include the app bundle id `com.rohunjoseph.aura` (Supabase
     validates the identity-token audience against it).
   - **Secret Key (for OAuth)** left blank — it and the Callback URL are for the web
     OAuth flow only, not native token sign-in.
   - **Allow users without an email** turned **on** — the app requests only the name
     scope, so Apple returns no email; otherwise Supabase rejects the sign-in.
2. **`delete-account` edge function** deployed (already in `supabase/functions/`).

## Architecture

### AuthStore (new; AuraKit, `@Observable @MainActor`)

The single source of truth for auth state, injected into the environment like
`SettingsStore` / `WeatherStore`.

- **Exposes:** `isSignedIn: Bool`, `userID: UUID?`, and a transient
  `status: AuthStatus` (`.idle` / `.signingIn` / `.error(String)`) for the UI.
- **Session source:** reads the current Supabase session on init and subscribes to
  `client.auth.authStateChanges`, so state is correct across launches
  (supabase-swift persists the session in the Keychain) and after refresh, sign-out,
  or expiry.
- **Methods:**
  - `signInWithApple() async` — runs the Apple flow, then
    `backend.signIn(idToken:nonce:displayName:)`, seeding the crew name from Apple's
    `fullName` when present (see crew-name flow below).
  - `signOut() async` — clears the Supabase session only.
  - `deleteAccount() async` — RPC (profile + cascade) **and** the edge function
    (removes the `auth.users` row), then signs out locally.
- **Seams (for tests):** talks to the existing `GroupRideBackend` protocol; a thin
  `AppleAuthenticating` protocol wraps `AppleSignInController` so the Apple flow can
  be faked (success / no-name / cancel / failure) without a device.

### Inline just-in-time gate

All three ways into a group ride converge on pushing `.groupRide(entry)`:
"Ride together" (create), the Join-by-code screen, and the `aura://join?code=` deep
link. The gate lives at that single choke point:

- `startGroupRide(entry)` checks `authStore.isSignedIn`.
  - Signed in → push `.groupRide(entry)` unchanged.
  - Signed out → present Sign in with Apple as a **sheet** over the current screen.
    On success → continue the original action (push the route). On cancel/failure →
    dismiss, stay put, no navigation.
- The deep-link path routes through the same gate. The existing `isRideActive` guard
  still drops links during an active solo ride (unchanged).
- `GroupRideSession.create()/join()` keep their auth assumption as a safety net, but
  are no longer the first line of defense.

Exact host of the gate state (AppRouter vs. RootView holding the pending entry +
sign-in sheet) is settled in the plan; the contract is: one reusable entry, one
sheet, resume-or-abandon the original intent.

### Settings account section

A new **Account** section in `SettingsView`:

- **Signed out:** an Apple-styled "Sign in with Apple" button with a one-line
  subtitle (rides-with-your-crew); runs `authStore.signInWithApple()` inline.
- **Signed in:**
  - **Crew name** — the existing `DisplayNameEditor` link moves here.
  - **Sign out** — `authStore.signOut()`; local ride history and saved crew name are
    kept so re-sign-in is seamless.
  - **Delete account** — destructive, behind a confirmation alert whose copy states
    it removes the crew profile and server-side group-ride data but **not** local
    ride history (on-device / iCloud, unrelated to the account).

### Crew-name flow (ordering fix)

- First sign-in, **name present** → passed into `backend.signIn(...)` (which calls
  `upsert_display_name`) and mirrored to the local `crewDisplayName`. Set server-side
  and locally at once; rider flows straight into the ride.
- First sign-in, **name absent** → crew name stays empty; the rider hits the
  crash-free `.needsDisplayName` screen, now while authenticated, so Save succeeds.
- Later sign-ins → local crew name already exists; no prompt.
- `DisplayNameStore.save()` robustness fix: push to the backend first, then mirror
  locally on success, so a failed save can't leave a phantom local name that skips
  the gate while the server profile stays blank.

## Error handling

- **Apple sheet cancel** (`ASAuthorizationError.canceled`) → silent no-op.
- **Apple / network / Supabase failure** → `status = .error(message)` with a friendly,
  retryable line, shown in the sheet and Settings.
- **Provider misconfig / bundle-id mismatch** → surfaces as that same sign-in error
  (not a crash); clears once the Supabase provider config is saved.
- **Session expiry / refresh** → handled by `authStateChanges`; a mid-ride refresh is
  invisible, and a lost session simply re-gates the next group action. Live-layer
  reconnect/disconnect handling is unchanged.

## Testing

- `AuthStore` unit tests against the in-memory `GroupRideBackend` fake + a fake
  `AppleAuthenticating`: success, no-name, cancel, failure; `isSignedIn`/`userID`
  transitions; crew-name seeding for name-present and name-absent.
- Gate branching (signed-in pushes directly vs. signed-out presents the sheet then
  resumes) tested at the seam.
- `DisplayNameStore.save()` ordering test (local mirror only after backend success).
- End-to-end device verification of the real Apple + Supabase path once the provider
  config is in.

## Review reconciliation (adversarial spec review, 2026-07-07)

Three independent refuting reviewers (correctness, iOS/Apple, UX/edge) ran against
the approved design. These resolutions supersede any ambiguity above and are binding
on the plan.

### Presentation & the gate (was under-specified)

- **`AppleSignInController.presentationAnchor(for:)` must not return a bare
  `ASPresentationAnchor()`** — that is an unattached window and fails on a real device
  (the simulator masks it). Return the active foreground window scene's key window:
  resolve `UIApplication.shared.connectedScenes`, pick the foreground-active
  `UIWindowScene`, return its key window; fall back safely if none. This is a fix to
  existing code, covered by the plan.
- **The gate presents no competing SwiftUI `.sheet`.** `ASAuthorizationController`
  owns the system Sign-in sheet. Tapping a group action while signed out calls
  `authStore.signInWithApple()` directly; the Apple system UI presents over the key
  window; on success the gate continues. (The Settings button likewise triggers the
  controller directly.)
- **Gate host is `AppRouter`** (not view-local state), so the pending intent survives
  view teardown and the deep-link round-trip. Concretely: `AppRouter` gains
  `startGroupRide(_ entry:)` and holds `pendingGroupEntry: GroupRideEntry?`.
  - Signed in → push `.groupRide(entry)`.
  - Signed out → store `pendingGroupEntry = entry`, trigger sign-in; on success push
    the stored entry and clear it; on cancel/failure clear it and stay put.
  - **Reentrancy guard:** a second `startGroupRide` while one is pending is ignored
    (no double sign-in, no double push).
  - `handle(url:)` routes `.groupRide(.join(code))` through `startGroupRide`, so a
    deep-link join code is captured in `pendingGroupEntry` and survives sign-in.
  - `RoutePreviewView` "Ride together" and `GroupRideJoinView` join call
    `startGroupRide` instead of `router.push(.groupRide(...))` directly.

### AuthStore lifecycle (was under-specified)

- **Cold-launch correctness:** read `client.auth.currentSession` **synchronously** at
  init (it reads the Keychain, no network) to set `isSignedIn`/`userID` immediately —
  do not depend on the async stream's first emission, which can be delayed or (offline)
  emit nil. This also makes the app correct on an offline cold launch.
- **Subscription lifetime:** own a retained `Task` running
  `for await (event, session) in client.auth.authStateChanges { … }` for the store's
  lifetime (stored property, cancelled on deinit). The store is a single long-lived
  `@State` in `AuraApp`, injected into the environment like the other stores.
- **Single client:** AuthStore reads auth off `SupabaseClientProvider.shared` — the
  same client `SupabaseGroupRideBackend` uses — so there is exactly one session.
- **Best-effort name seeding:** a successful `signInWithIdToken` means signed-in.
  Seeding the crew name (the `upsert_display_name` push) is best-effort — if only the
  name push fails, the user is still signed in and falls through to the (now working)
  name screen. A name-push failure must not present as an auth failure.

### Crew-name correctness (account switch + save ordering)

- **Account switch must not leak a name.** The local `crewDisplayName` key is not
  user-scoped, so a prior user's name can bleed into a different Apple ID. Resolution:
  on sign-in, the signed-in user's **server profile display_name is the source of
  truth** — AuthStore seeds local from Apple's `fullName` only when the server profile
  has none; and it detects a user switch (persist `lastSignedInUserID`) and clears the
  stale local name on switch. Delete-account also clears the local crew name.
- **`DisplayNameStore.save()` ordering (confirmed still local-first in code):** push to
  the backend first, then mirror to UserDefaults only on success.

### Sign-out / delete-account during a live ride

- Settings is unreachable during an active ride (the full-screen ride HUD hides
  navigation and sets `isRideActive`), so mid-ride sign-out/delete is largely moot.
  Defensive guard anyway: `signOut()`/`deleteAccount()` are disabled/blocked while
  `router.isRideActive` is true, with a one-line "end your ride first" note.

### Error classification

- With the gate ensuring auth **before** navigation, an unauthenticated user no longer
  reaches `create()`/`join()`, so the auth-failure-as-"route too detailed" mislabel is
  no longer on the happy path. Minor in-scope tidy: `.createFailed` copy is made generic
  ("Couldn't start the group ride — try again") rather than implying the route is the
  cause. Deeper per-error classification stays out of scope.

### External dependencies (additions)

- **Apple Developer portal:** the `com.apple.developer.applesignin` capability must be
  enabled for App ID `com.rohunjoseph.aura`, or automatic signing produces a profile
  without the entitlement and sign-in fails at runtime. (Entitlements file already
  declares it; the portal capability is the missing half.)
- **Verify** the deployed `delete-account` edge function actually removes the
  `auth.users` row (App Store account-deletion requirement), not just the profile.

### UI / compliance

- The Settings "Sign in with Apple" affordance uses the native `SignInWithAppleButton`
  (AuthenticationServices) for HIG compliance rather than a hand-rolled button.

### Testing (addition)

- Sign in with Apple is **device-only** for verification — the simulator's lenient
  window handling can mask the presentation-anchor bug. Unit tests cover the seams
  (fake `AppleAuthenticating` + in-memory backend); the real Apple + Supabase path is
  verified on the physical device after the portal + provider config is in.
