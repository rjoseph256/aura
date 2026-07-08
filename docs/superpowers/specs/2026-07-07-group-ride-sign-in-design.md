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
