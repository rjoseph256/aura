# Aura device testing

Everything below needs a real iPhone (and for some items, two). These are the checks the
simulator and CI could not prove, collected from the ROADMAP device-verify lists for group
rides, iCloud sync, and the earlier waves. Work top to bottom: Sign in with Apple and
provisioning come first because later items depend on them.

## One-time setup

**Signing and capabilities.** Open the project (run `cd Aura && xcodegen generate` first), pick
the team `C3LFTV2QYK`, and let Xcode manage signing for both `com.rohunjoseph.aura` and the
`AuraWidgets` extension. On the App ID, enable these capabilities (Xcode automatic signing will
add most of them once the entitlements file is present):

- Sign in with Apple
- HealthKit
- App Groups: `group.app.aura.ios`
- iCloud with CloudKit, container `iCloud.com.rohunjoseph.aura`
- Background Modes: Location updates (already declared in Info.plist)

**Supabase.** Deploy the `delete-account` edge function so account deletion works. The two
Realtime dashboard settings ("Allow public access" off, message retention 48h or less) are
already done.

**Two-device matrix.** The two features that need two devices need them set up differently:

- Group rides: two iPhones, each signed into a *different* Apple ID, because they are two
  separate riders. Both accounts need Sign in with Apple working.
- iCloud sync: two devices signed into the *same* iCloud account. A second iPhone works; so does
  one iPhone plus a simulator signed into the same iCloud.

**Building to the device.** Select your iPhone in Xcode and Run, or use the `ios-build-verify`
tooling to deploy. For a second identity you may need a second physical phone; Sign in with Apple
cannot run two accounts on one device at once.

**Capturing evidence.** Use Console.app filtered on the `Aura` process (or the Xcode console) for
`os_log` output, the Health app for workouts, the CloudKit Dashboard at
icloud.developer.apple.com for the ride record type, and the Xcode Organizer for any crash logs.
Keep a running table: item, date, device(s), pass or fail, notes and screenshots.

## 1. Sign in with Apple (do this first)

Group rides will not work without it. Launch the app, trigger sign-in, complete the Apple sheet,
and confirm a Supabase session exists (a row in `auth.users` and a matching `profiles` row, which
you can check with the Supabase MCP or dashboard). Then exercise account deletion.

Pass: sign-in succeeds on both Apple IDs, a profile row exists for each, and deletion removes the
user and their data.

## 2. Locked-screen background recording

This is the flagship behavior a cycling app has to get right, and the simulator cannot prove it.
Start a free ride, lock the phone, move for several minutes, then unlock and end the ride.

Pass: the recorded track has no gap across the locked stretch, distance and moving time kept
advancing, and the ride saved. Inspect the track on the ride summary map.

## 3. Live speedometer

On a ride with real speed changes, watch the HUD dial while you speed up and slow down.

Pass: the dial follows your current speed and reacts to changes, instead of settling near the
ride average.

## 4. HealthKit

Turn on "Save rides to Health," grant write access, and finish a ride. Then turn the toggle off
and finish another.

Pass: a Cycling workout appears in the Health app with distance and a GPS route for the first
ride, nothing is written for the second, and there is exactly one workout per saved ride.

## 5. Turn haptics and arrival

Navigate a route with the "Turn haptics" toggle on. Feel for the approach buzz as each turn comes
within about 150 m and the arrival cue at the destination. Then toggle it off and repeat.

Pass: the approach fires once per turn, the arrival fires once, and the toggle silences both. The
arrival cue is the specific one the simulator's teleporting GPS could not trigger, so confirm it
here.

## 6. Live Activity and Dynamic Island

During a ride, check the Lock Screen Live Activity and the Dynamic Island in its compact, minimal,
and expanded forms. On a navigated ride the next turn should lead.

Pass: elapsed time ticks on the Lock Screen, stats update as you move, and the turn distance turns
green as the maneuver nears.

## 7. Widgets

Add the Weekly goal and Last ride widgets to the Home Screen and the Lock Screen, and check
StandBy (a device-only surface).

Pass: both render live data from the App Group, the weekly ring reflects your goal, and the last
ride widget draws the real route thumbnail.

## 8. Group rides (two devices, two Apple IDs)

This is Aura's signature surface, so give it the most attention. Device A signs in as rider 1,
Device B as rider 2.

1. Create and join. On A, plan a route and tap "Ride together," then share the 8-character code
   or the `aura://join?code=` link. On B, join by the code or the link.
   Pass: both reach the rolling-join lobby, then the live navigate HUD. Each device shows the other
   as a named dot on the map, colored by status (white for you, mint riding, amber stopped, grey
   dropped). The roster sheet shows ahead or behind distance for each peer.
2. Membership toasts. Watch for the join, left, and host-ended toasts as riders come and go.
3. Host End. The host taps End. On the member's device the crew layer should dissolve while solo
   turn-by-turn navigation keeps running.
4. Member Leave. A member taps Leave. They keep riding solo, the host sees them go, and the ride
   frees their slot.
5. Reconnect. Put Device B in airplane mode for about 30 seconds mid-ride. Expect the
   "Reconnecting..." pill while the connection is down, then peers reappearing after the snapshot
   re-seeds on reconnect.
6. Load. If you can get up to eight riders into one ride, watch the map stay smooth with eight
   peer annotations and the pulse animation running.

Pass: each step behaves as described, positions stay roughly accurate, and no rider's dot lingers
after they leave.

## 9. iCloud sync (two devices, same iCloud account)

First provision the schema. On a signed build, run the app once so SwiftData pushes the CloudKit
schema, then open the CloudKit Dashboard Development environment and confirm the `CD_RideRecord`
record type and its fields appear. Promote the schema to Production before any TestFlight or App
Store build, and after promotion only add to it.

1. Ride round-trip. Record a ride on Device A. With Device B open on the History tab, the ride
   should appear without relaunching. Check the Plan tab and its weekly ring update too.
2. Settings convergence. On A, change units, weekly goal, map style, voice, and turn haptics.
   Confirm each changes on B. Confirm "Save rides to Health" does *not* cross, since it stays
   device-local.
3. Widget refresh. After changing the goal on A, the widget on B should update.
4. Account changes. Sign out of iCloud on a device and confirm the app still records locally and
   does not crash, then sign back in and confirm sync resumes. Switch to a different Apple ID and
   confirm the first account's rides do not show under the second.
5. Backup restore (optional). Restore an iCloud backup onto a device that also has cloud rides and
   confirm History shows no duplicates, which exercises the dedup-on-read guard.

Pass: rides and the four synced settings converge across devices, the widget follows, sign-out and
account switches never lose or crash, and duplicates never appear.

## When something fails

Capture the repro steps, the device and OS version, and a screenshot or the relevant Console log,
then file it as a bug. Most of these paths are correct-by-construction and unit-tested, so a
failure usually points at a wiring or provisioning gap rather than the core logic.
