# Crew Family — group-ride surface pass (design)

**Date:** 2026-08-31 (v2, reconciled after the 3-reviewer adversarial spec gate)
**Epic:** Interface & Feel — third sub-pass of [ROH-45](https://linear.app/rohun/issue/ROH-45); umbrella issue ROH-225.
**Status:** reconciled; awaiting PO review + three PO decisions (§2) + the identity-board mockup gate.
**Verification:** Tier 1 for the visual work; **Tier 2 (two-phone, queued)** for the lobby-fill fix and per-device hue coherence — the v1 "Tier 1 throughout" claim was wrong (VERIFICATION.md's Tier-2 list names the join/lifecycle family).

## 1. Context — what the gate changed

v1 was written from the audit; the gate (skeptic / product / architecture, all three
landing blockers) rewrote its foundations:

1. **The lobby's core function is broken, and v1 was about to decorate it.** A host's
   roster does not fill when friends join: `refreshRoster()` runs only from
   `beginLiveSession()` and on an incoming `.position` from an unknown peer
   (`GroupRideSession.swift:271,308`), no `member_joined` event exists in the
   transport (`SupabaseRideSessionTransport.swift:156-161`), and positions don't flow
   until riding. The preview host only "fills" by hand-injecting positions the lobby
   never produces. Fixing this is now Workstream A0 — the slice's most important item.
2. **"Hue = identity" via `PeerPalette.assign` was mathematically false.** The
   collision-avoiding assignment is input-set-sensitive: reviewers measured existing
   riders' hues reshuffling on ~39% of membership changes and map-vs-roster
   disagreement growing from 9% (2-rider crew) to 76% (6). The already-approved
   ROH-114 spec (§D3.3, "One colour authority") settled the right design and v1
   missed it: **`RiderColorLatch`** — peers-minus-self input, first-assignment
   **latched** so a rider's hue never changes mid-ride, palette widened to 8. This
   slice implements that spec rather than inventing a competitor. Cross-DEVICE hue
   agreement is explicitly not promised (different join orders latch differently);
   the promise is per-device stability + cross-surface consistency on one device.
3. **Distinct join-failure copy cannot ship and v1 cited the evidence backwards.**
   The server's single generic `'join failed'` is a deliberate anti-enumeration
   oracle, documented in three places (`0003_join_ride.sql`, `0014`, `0021:78`;
   `COLLABORATOR-TASKS.md:39` — "the single generic error is deliberate"); ended vs
   nonexistent code are structurally indistinguishable even server-side. The item is
   cut; the oracle question is filed as its own security decision (ROH-226). What IS
   client-detectable and more common: **network failure vs server rejection** —
   `SupabaseGroupRideBackend.joinRide` currently collapses both
   (`SupabaseGroupRideBackend.swift:56`), so a rider with one bar is told to
   double-check their code. That split ships instead.
4. **The failed join is a dead end and the exit, not the copy, is the fix:**
   `.joinFailed`'s only control pops to Home; the typed code is gone
   (`GroupRideFlowView.swift:112-116,200-202`). Recovery paths are now Workstream D's
   center.
5. **The v1 code-reveal motion animated a state production can't reach** —
   `joinCode` is always set before the phase becomes `.lobby`
   (`GroupRideSession.swift:155-163,199-211`); the "········" placeholder is a
   preview-race artifact. Cut. This slice adds **no new motion**.
6. **The Theme-wide disabled-CTA restyle is cut.** The inventory was wrong (5 sites,
   not 2; the named evidence site is an unfilled variant the rule didn't cover) and
   most sites are *transient/progress* states where "inert grey" is the wrong
   message. The join screen fixes its disabled Join with layout + an explanatory
   caption instead (GemDetailSheet's "Waiting for GPS…" precedent).
7. **`.mapCard` is cut** (hygiene not rider value; the name lied for the non-map
   lobby; moving the material into Theme would widen the drift surface the lint rule
   guards). The identity-carriers lint exemptions stand as settled; that session has
   been told. **This dissolves the hard dependency on the identity-carriers branch**
   — remaining coordination is file-level only (§8).

Still true from the audit and in scope: three join-code voices, the "JOIN CODE"
eyebrow, the half-void join screen with a trapped keyboard, duplicated empty states,
the bare entry spinner, the unframed name prompt — plus gate discoveries: the roster's
self row renders "**You YOU**" (`GroupRosterSheet.swift:255-263`), the lobby's crew
count includes yourself ("Crew · 1 joined" = me, `GroupLobbyView.swift:166-170`), and
pasting the shared `aura://join?code=…` link produces charset-filtered garbage
(`GroupRideJoinView.swift:38-40` vs `GroupLobbyView.swift:40`).

## 2. Decisions — settled here, plus three for the PO

**Settled (gate-driven):**
- **Adopt `RiderColorLatch` per ROH-114 §D3.3** (peers-minus-self, latched, 8-hue
  palette per that spec) as the one color authority; migrate the map's assignment to
  it (fixing today's live mid-ride reshuffle) and use it for lobby monograms.
  Monogram labels derive from `nameMap`/`peer.displayName` — never the roster's
  literal "You" label (self contributes no monogram; self is excluded from the set).
- **The roster keeps its status grammar.** The product lens made the argument v1
  skipped: on the map there are no names, so hue must do identity work; in the
  roster the names are present and the host's question is "who's in trouble" — the
  mint/amber status avatars answer it instantly and survive. Identity hues therefore
  ship on the **map and lobby**; the roster changes only its bugs ("You YOU", and
  no dimming of `.awaiting` — that re-litigated ROH-214's "healthy ride starts
  amber" finding through a channel with no words behind it). *(PO can override —
  decision 3 below.)*
- **No Theme CTA change; no new motion; no `.mapCard`;** join-failure reasons are
  network-vs-rejected only, never server-guessed; generic rejection copy becomes
  cause-agnostic.
- **Sentence case everywhere** ("Join code"); one `JoinCodeText` voice for the lobby
  card and roster empty state (the join screen's per-character boxes stay per-box —
  §10 no longer claims "one voice" beyond that).

**PO decisions — ANSWERED 2026-09-01: 1a, 2a, 3a (all recommendations).** The lobby
fills by roster poll; the Join button stays explicit with the caption; the roster
keeps status colors. Recorded here; the options below stay for the rationale record.
1. **Lobby fill mechanism** — (a) *recommended:* client-only roster poll while
   `phase == .lobby` (every ~4s; no migration, no new server surface, Tier-2
   verifiable on the existing two-phone queue), or (b) a `member_joined`
   Broadcast-from-Database (real-time, but a migration + transport bridge on the
   security-reviewed join path).
2. **Join action** — (a) *recommended:* keep the explicit Join button, pinned above
   the keyboard, with a caption explaining the disabled state, or (b) auto-join on
   the 8th valid character (dissolves the disabled state entirely; some riders want
   a confirm step).
3. **Roster avatars** — (a) *recommended:* keep status colors (per-surface grammar
   above), or (b) identity hues everywhere with status moved to pills (requires
   inventing an `.awaiting` pill and re-opens the ROH-214 ground).

## 3. Workstream A0 — make the lobby fill (the headline)

Assuming decision 1a: while `phase == .lobby`, the session polls `refreshRoster()`
on an injected-clock interval (~4s), stopping on any phase exit; the existing
`.position`-triggered refresh stays. Joiner rows appear under the lobby's existing
0.22s row animation — the *real* waiting-moment payoff v1 misspent on the fake code
reveal. Pure-logic cadence lives in AuraKit with tests (injected clock, per the
end/leave timeout precedent at `GroupRideSession.swift:133`); the poll must be
idempotent with `beginLiveSession()`'s seed.

**Verification: Tier 2, two-phone, queued** — host lobby fills within one poll
interval of a second phone joining. This is the slice's merge-worthiness bar: if A0
doesn't land, the rest is paint on a broken room.

## 4. Workstream A — one color authority (`RiderColorLatch`, ROH-114 §D3.3)

- Implement `RiderColorLatch` in AuraKit exactly as the approved ROH-114 spec
  defines it: peers-minus-self input, latch-on-first-assignment (a rider's hue never
  changes for the session's lifetime), 8-hue palette (the widening is ROH-114's own
  decision; `AuraPalette` gains the three hues under the same CVD/WCAG test regime
  as the existing five — `riderInk` already picks ink by measured contrast).
- Session-owned: the latch lives on/with `GroupRideSession`; surfaces **look up**,
  never recompute (the gate showed a shared *function* with three input sets is the
  disease). The map's `PeerAnnotationDriver` migrates from `PeerPalette.assign` to
  the latch — fixing the shipped mid-ride reshuffle. `PeerPalette.assign` remains
  for any non-session use; nothing new calls it.
- **Lobby rows** adopt identity: `CrewMonogram` (hued disc + `RiderMonogram` label,
  ink via `riderInk`) replaces the always-accent initial; self row shows the real
  name + a "You" marker and a white disc ("white = me", the puck grammar); the host
  row gains a "Host" marker (a guest currently can't tell who they're waiting on).
- **Roster**: avatars unchanged (decision 3a); fix "You YOU" (the name column shows
  the real display name, the marker stays); sort order untouched
  (progress-descending — v1's "self-first" claim was wrong).
- Latch tests in the package: stability across membership change (the exact case
  `PeerPaletteTests` misses), peers-minus-self input, lookup-miss fallback.
- Out of promise: cross-device hue agreement (stated, not hidden); open-ride crew
  layer (no roster/dots exist on `RideHUDView` — that is ROH-114 Plan 2, deferred
  there, and §10's coherence criterion is scoped to route rides accordingly).

## 5. Workstream B — join screen (`GroupRideJoinView`)

- **Keyboard:** a `.keyboard` toolbar "Done" item — reliable regardless of content
  height (the gate showed `scrollDismissesKeyboard` is a no-op when content fits,
  which the tightened layout makes *more* likely) — plus `.submitLabel(.join)`.
  No ScrollView; the full-screen tap-to-focus target and background stay as built.
- **Layout:** the entry cluster (boxes → paste → Join) sits together; Join pins via
  `.safeAreaInset(edge: .bottom)` so it remains visible keyboard-UP on an SE — the
  gate showed v1's layout put the button under the keyboard at the exact moment it
  enabled, and that a keyboard-down mockup can't catch it. **Gate evidence must
  include the keyboard-up SE state.**
- **Disabled Join:** keeps the standard style; gains a caption underneath while
  incomplete — "Enter the 8-character code from your host." — cleared when valid
  (decision 2a; if the PO picks auto-join, the caption and the disabled state both
  vanish).
- **Paste:** parse an entire shared link — if the pasteboard contains
  `aura://join?code=XXXXXXXX` (the exact string the lobby's Share writes), extract
  the code; otherwise sanitize as today. Small pure helper, package-tested.
- **Dynamic Type:** the code boxes keep `metricCockpit(20, relativeTo: .title3)`
  (v1's bump to 24 is dropped — no clipping guard existed) and the screen gains the
  roster's `dynamicTypeSize(...accessibility1)` cap. v1's filled-box-brightening cue
  is dropped (the glyph appearing IS the progress; the extra border spent accent on
  decoration).

## 6. Workstream C — code voice and waiting states

- `JoinCodeText` (Saira cockpit, one tracking token, size parameterized): lobby card
  + roster empty state. "JOIN CODE" → "Join code", sentence case.
- `CrewEmptyState` with the **three** real variants (lobby; roster-with-code +
  share hint; roster-without-code guest line) — v1 enumerated two and would have
  silently dropped the guest copy the earlier review gate added.
- **Lobby predicate + count fixes:** empty-state trigger becomes `rows.count <= 1`
  (matching the roster — today's `rows.isEmpty` is unreachable because the seed
  roster includes the host, so a waiting host sees their own name as "Crew · 1
  joined"); the count label excludes self ("Crew" until a friend arrives, then
  "Crew · N joined" where N counts the others).
- No new motion anywhere in this workstream.

## 7. Workstream D — flow states (`GroupRideFlowView` + session seam)

- **Loading:** entry-aware copy — create → "Setting up your crew ride…", join →
  "Joining your crew…" — with glyph + spinner; **bounded** by the session's
  existing injected-clock timeout pattern (end/leave precedent): a hung create/join
  resolves to the connection-failure surface rather than an eternal spinner.
- **Failure taxonomy (client-only):** `SupabaseGroupRideBackend.joinRide` and
  `create` distinguish transport-reachability failures (URLError et al →
  `.connectionFailed`) from server rejection (`.rejected`). No server change; no
  guessed reasons. Session carries the reason in a property **alongside** the
  payload-free phase (an associated value would break `phase ==` and the ROH-81
  single-branch `if`), cleared at the top of every attempt and written adjacent to
  the phase with no suspension between (the gate's split-state rules).
- **Copy:** rejected → "Couldn't join that ride. Check the code with your host and
  try again." (cause-agnostic — full/ended/typo all land here honestly);
  connection → "Couldn't reach the ride — check your connection and try again."
- **Exits, not dead ends:** the join-failure surface offers **Try again** —
  returning to the join screen with the typed code preserved (the screen's `seed:`
  init already exists for previews) — plus Back; `.createFailed` gains Try again
  (re-invokes the entry) plus Back. Route stays on `replaceTopWithGroupRide`
  mechanics; no new NavigationStack; the ROH-81 structural branch is untouched.
- **Name prompt framing:** `DisplayNameEditor` gains a defaulted `contextLine`
  parameter placed after `onSaved` (trailing-closure call sites must keep
  resolving; Settings stays byte-identical), and the flow passes "Pick a crew name —
  it's how your crew sees you."
- The corrupt-payload branch shares the routeUnavailable copy today and gains the
  same secondary line — five `dismissMessage` call sites, not three.

## 8. Dependencies, coordination, verification

- **No hard dependency on the identity-carriers branch remains** (§1.7). File-level
  coordination only: that branch has one in-flight line in
  `GroupRideMapOverlay.swift` (which this slice no longer touches) and this slice's
  map-latch migration touches `PeerAnnotations.swift` (which that branch does not).
  Sequencing courtesy: don't land the `PeerAnnotations` change while their branch is
  un-merged without a rebase check.
- **Tier 1 (sim):** join screen states (incl. keyboard-up SE), lobby/roster
  statics via previews **with frozen UUIDs** (the gate showed fresh-`UUID()`
  previews make hue evidence non-reproducible), rejection copy by typing a wrong
  code against the live backend, connection copy via network-off sim.
- **Tier 2 (two-phone, queued):** A0 lobby fill; per-device hue stability across a
  mid-ride join; appended to the existing two-phone session queue.
- **Accessibility:** new-hue ink pairs ride the existing `RiderPaletteTests` regime;
  Increase Contrast / Reduce Transparency passes on touched surfaces (toggle recipe
  in §8 of v1 retained: `simctl ui` has only `increase_contrast`; RT via Settings or
  `EnhancedBackgroundContrastEnabled` in `com.apple.Accessibility`; verify the
  toggle flipped before judging code).

## 9. Out of scope

The join-oracle security decision (filed as its own issue — ROH-226); any server
migration (unless PO decision 1b); the open-ride crew layer (ROH-114 Plan 2, stays
deferred); QR join; group Live Activity; peer-focus; host transfer; membership
toasts; `.mapCard`/lint hygiene (cut); Theme CTA changes (cut); roster visual
redesign beyond the named fixes; `GroupNavigateContainer`/HUD chrome; the latent
`selfUserID ?? UUID()` random-identity default in `NavigateHUDView+GroupCrew.swift:28`
(noted for the identity-carriers file boundary; a one-line follow-up once that
branch lands).

## 10. Success criteria

1. Two-phone: a host's lobby shows a joining friend within one refresh interval,
   with the arrival row animating in (A0 — the merge-worthiness bar).
2. On one device, in a route ride, a given peer renders the same hue and monogram
   on the map and in the lobby, and that hue never changes mid-session — pinned by
   latch tests (stability across membership change) and eyeballed on the two-phone
   pass. Cross-device agreement is explicitly not claimed.
3. The map's mid-ride hue reshuffle is gone (latch replaces `PeerPalette.assign`
   in the driver).
4. Lobby rows: identity hues + real names + You/Host markers; roster: status
   grammar intact, "You YOU" fixed, `.awaiting` presentation unchanged.
5. Join screen: Join visible keyboard-up on an SE; keyboard dismissible via Done;
   disabled Join carries its caption (or doesn't exist, per decision 2); pasting
   the shared link fills the code correctly; Dynamic Type capped like the roster.
6. One `JoinCodeText` voice at both non-box sites; no uppercase tracked eyebrows in
   the group module; three-variant `CrewEmptyState`; lobby count excludes self and
   its empty state is reachable.
7. Loading is entry-aware and bounded; rejection and connection failures show
   distinct, honest copy; both failure surfaces offer Try again (code preserved on
   the join path); the name prompt is framed; Settings' editor is unchanged.
8. No new motion; no Theme-wide style changes; `swiftlint --strict` + both package
   test totals green; every new pure seam (poll cadence, latch, paste parser,
   failure mapping) is package-tested.

## 11. Board mechanics

Child issues under ROH-225 per workstream (A0, A, B, C, D) once the PO approves
this spec and answers §2's three decisions; the oracle question files as ROH-226
(Backlog, security decision, not this slice). Suggested order: A0 → D → B → C → A
(the fill fix first — everything else is worth less until the room works); the plan
stage owns final sequencing.
