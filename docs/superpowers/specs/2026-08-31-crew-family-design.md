# Crew Family — group-ride surface pass (design)

**Date:** 2026-08-31
**Epic:** Interface & Feel — third sub-pass of [ROH-45](https://linear.app/rohun/issue/ROH-45), following identity carriers.
**Status:** drafted from the 2026-08-31 premium audit under the PO's standing directions; awaiting adversarial spec review, then PO review + mockup gate.
**Verification:** Tier 1 throughout (static UI, preview-drivable); one queued Tier-2 two-device check (§8).

## 1. Context

The 2026-08-31 audit ranked the Crew/group-ride family as the app's second-weakest
flow — and it is the PO's stated signature surface ("flagship-beautiful"). Findings,
verified against code this session:

1. **Three monogram implementations, none using the rider palette built for this.**
   `LobbyRosterRowView` (always accent fill, `GroupLobbyView.swift:313-320`),
   `RosterRowView` (status-colored fill, `GroupRosterSheet.swift:297-312`), and the
   map's `PeerDotView` — and only the map consumes `AuraTheme.riderPalette` /
   `riderInk`. The same rider is mint in the lobby and cyan on the map.
2. **The join code renders in three voices:** lobby `metricCockpit(40)` + tracking 4
   (`GroupLobbyView.swift:127-132`); join boxes `metricCockpit(20)`; roster empty
   state `.monospaced` title3 + kerning 2 (`GroupRosterSheet.swift:206-208`).
3. **"JOIN CODE"** is an uppercase tracked eyebrow (`GroupLobbyView.swift:122-125`) —
   the slop gate the codebase itself documents forbids these (`HomeView.swift:311`).
4. **The join screen is half void** with a "muddy" disabled Join — `ctaPrimary` at
   `opacity(0.4)` (`CTAButtonStyle.swift:18`), i.e. ghost mint, reading half-pressed
   rather than inert. The keyboard cannot be dismissed once up — a documented known
   gap whose fix (a scroll view) the file's own header already prescribes
   (`GroupRideJoinView.swift:15-20`).
5. **The code reveal is a hard swap** ("········" → code,
   `GroupLobbyView.swift:146`) on a screen whose entire purpose is waiting; the only
   lobby animation is `rows.count`.
6. **The "Waiting for your crew…" empty state is written twice**
   (`GroupLobbyView.swift:188-200`, `GroupRosterSheet.swift:196-221`).
7. **The flow's entry loading is a bare unlabeled `ProgressView`**
   (`GroupRideFlowView.swift:71-74`) in a codebase that designed a labeled skeleton
   for route preview; **all join failures collapse to one generic message** — the
   session maps every thrown error to `.joinFailed`
   (`GroupRideSession.swift:178-180`), though the roadmap notes the server
   distinguishes full / ended / bad code; **`needsDisplayName` drops the rider into a
   bare `DisplayNameEditor`** with no framing of why they're being asked
   (`GroupRideFlowView.swift:76-85`).

Deliberately good things this slice must not break: the roster's **attention
semantics** (badge tint = warning only on a dropped rider — adversarially gated in
ROH-214; stopped/awaiting stay calm), the ROH-81 single-structural-branch phase
handling in `GroupRideFlowView`, the single-path `replaceTopWithGroupRide` navigation
(device-caught NavigationStack double-mutation), and the roster empty state's
join-code presence (a prior review-gate finding).

## 2. Design decisions

- **Hue = identity, everywhere; status is never a hue.** One `CrewMonogram` component
  renders every crew avatar from the SAME assignment the map dots use —
  `PeerPalette.assign(userIDs:paletteCount:)` for the hue index,
  `RiderMonogram.assign(names:)` for the label, `AuraTheme.riderColor/riderInk` for
  paint. **Self is white with ink text** — the same "white = me" grammar the
  identity-carriers puck and the map's self-precedent use. Status moves entirely to
  non-chromatic channels: the existing status pill text, plus a dimmed avatar
  (opacity, not hue) for dropped/awaiting. The crew button's three-state badge tint
  and `CrewButtonSummary` logic are untouched.
- **One assignment, one source.** Hue/label maps are derived ONCE per session from
  one userID set (all current members, self included) and handed to every surface.
  `PeerPalette.assign` is collision-avoiding over its input set, so two surfaces
  passing different sets can disagree — the invariant is single-derivation, and it
  gets a test.
- **One join-code voice.** A `JoinCodeText` component (Saira cockpit face, one
  tracking value, size parameterized) replaces the lobby card text and the roster
  empty-state's monospaced rendering. The join screen's per-character boxes already
  use the cockpit face and stay per-box.
- **Sentence case.** "JOIN CODE" becomes "Join code". No tracked uppercase eyebrows.
- **A designed disabled state for CTAs, Theme-wide.** `CTAButtonStyle` disabled
  filled variants render `surface` fill + `textSecondary` label + hairline border
  instead of 40%-opacity accent — clearly inert, never "muddy". This changes every
  disabled CTA in the app (Join here; the summary's disabled Share is the other
  shipped site) — both appear in the gate evidence.
- **The lobby's waiting moment gets its one sanctioned motion:** the code reveal
  animates (a ~200ms state-conveying transition — content replace/fade, Reduce
  Motion branch renders the swap), and roster rows keep their existing 0.22s ease.
  Nothing ambient, per charter.
- **Card treatment goes shared.** A `.mapCard(shape:)` Theme modifier captures the
  lobby/roster stacked treatment (surface 0.9 over `.ultraThinMaterial`, with the
  `prefersOpaqueSurface` branch) that both files currently hand-roll. With the
  material usage moved into `Theme/`, the two per-file lint exemptions identity
  carriers added are **deleted** — the drift-guard rule goes back to
  Theme-plus-widgets only. Per the executing session's caveat: the lint rule only
  permits location; the Increase Contrast / Reduce Transparency correctness of these
  cards is this slice's to test in the sim pass.
- **Per-element PO approval** (standing direction): the identity board — monogram
  system across lobby/roster/map, `JoinCodeText`, the rebuilt join-screen layout, and
  the disabled-CTA treatment — is mocked up and PO-approved before implementation
  rolls out (§7).

## 3. Workstream A — crew identity system

- New `CrewMonogram` view: hued disc + monogram label, sizes for lobby/roster rows
  (32pt today) parameterized; self = white disc, ink label; dropped/awaiting render
  at reduced opacity (status pill still carries the words).
- A single identity derivation — a small pure helper in AuraKit (testable) that maps
  the session's member set to `{userID: (hueIndex, monogram)}` via the existing
  AuraCore seams, consumed by lobby rows, roster rows, and (after the
  identity-carriers branch merges — file overlap) the map's `PeerDotView`/name-tag
  path if its inputs differ from this derivation.
- Lobby rows adopt `CrewMonogram` and gain the roster's "YOU" marker plus a "Host"
  marker (a guest currently cannot tell which lobby row is the host they are
  waiting on).
- Roster rows keep every current behavior (status pill, distance label, a11y labels,
  self-first semantics) — only the avatar's fill logic changes from status-colored to
  identity-colored + dim.

**A11y:** identity hues are the CVD-safe `riderHues` with contrast-picked ink
(`AuraTheme.riderInk`, WCAG-gated); status remains fully non-chromatic (text pill).
VoiceOver labels unchanged.

## 4. Workstream B — join screen rebuild (`GroupRideJoinView`)

- **Structure:** content moves into a `ScrollView` +
  `.scrollDismissesKeyboard(.interactively)` — the file's own documented fix for the
  trapped keyboard; the background tap-to-focus stays on the scroll content
  (unchanged semantics: tap focuses, drag dismisses).
- **Layout:** the dead middle goes. The entry cluster (code boxes → paste → Join)
  sits together under the header/start/divider column; Join is adjacent to what
  enables it instead of anchored across a void. Exact spacing settles at the mockup
  gate.
- **Code boxes:** type bumps to `metricCockpit(24)`; a filled box's border brightens
  one step so progress reads at a glance; the existing next-box accent focus ring
  stays.
- **Disabled CTA:** the Theme-wide change from §2 lands here (and is screenshotted on
  the summary's Share button too).
- Copy/casing already consistent on this screen ("Start a ride"); no copy changes.

## 5. Workstream C — lobby and waiting moments (`GroupLobbyView`, `GroupRosterSheet`)

- `JoinCodeText` replaces both non-box code renderings; "Join code" sentence-case
  label; code reveal transition per §2.
- One `CrewEmptyState(joinCode:)` component replaces the two duplicated
  "Waiting for your crew…" blocks — the roster variant keeps its join-code line and
  its share hint (review-gated behavior), the lobby variant omits them (the code
  card is directly above).
- `.mapCard` migration for the lobby code card and the roster expanded card; delete
  both lint exemptions; sim passes for Increase Contrast + Reduce Transparency on
  both cards (our correctness, not the rule's).
- The guest waiting row and host retry row are untouched except tokens they already
  use.

## 6. Workstream D — flow states (`GroupRideFlowView`, session seam)

- **Entry loading:** the bare spinner becomes a labeled state (glyph + "Setting up
  your crew ride…" + spinner) on the standard background — same shape as the app's
  other designed waits.
- **Distinct join failures:** `backend.joinRide` gains a typed error
  (`GroupRideJoinError`: `rideFull`, `rideEnded`, `invalidCode`, `other`), the
  session carries the reason alongside `.joinFailed`, and the flow maps it to copy:
  full → "This ride is full." / ended → "This ride already ended." / invalid →
  "That code didn't match a ride — double-check it with your host." / other → the
  current generic line. **Honesty gate:** the plan verifies the Supabase function
  actually distinguishes these server-side; any case it cannot distinguish falls to
  `.other` and the copy stays generic — no guessed reasons, ever (the join screen's
  doc comment already promises "this view never guesses at that outcome"). This also
  closes the roadmap's "distinct join-failure messages" Group-Rides-Tail item.
- **Name-prompt framing:** `DisplayNameEditor` gains an optional context line, and
  the flow's `needsDisplayName` phase passes one ("Pick a crew name — it's how your
  ride sees you."). Settings' use of the editor is unchanged.
- The ended/createFailed/routeUnavailable surfaces keep their structure; each gains
  a one-line secondary explanation where it has none.

**Structural cautions (from the code's own scars, binding on the plan):** the
`content` `if` in `GroupRideFlowView` (riding/ended sharing one structural branch,
ROH-81) is not refactored; navigation stays on `replaceTopWithGroupRide`; nothing
introduces a nested `NavigationStack`.

## 7. PO approval gates

1. **Crew identity board (mockup, before implementation of A/B visuals):** the
   monogram system shown across lobby row / roster row / map dot for the same fake
   crew (hue coherence visible), `JoinCodeText`, the rebuilt join-screen layout, and
   the disabled-CTA before/after. Same mockup-first process as the puck gate.
2. **Whole-slice before/after set:** lobby (empty + filling + guest), roster
   (collapsed/expanded, statuses), join screen (empty/partial/valid/disabled →
   enabled), flow states (loading, three failure copies, ended, name prompt) — the
   in-memory preview hosts drive most of these without a network.

Wait protocol as before: blocked status + Linear comment while a gate waits; rebase
before merge if main moved.

## 8. Dependencies and verification

- **Branch-level dependency (per the executing session, 2026-08-31):** identity
  carriers executes as ONE branch; ROH-222 does not merge separately. Crew
  **implementation** starts after that branch merges to main; spec, plan, and
  mockups proceed now. The `.mapChip`/`MapChipStroke` signature and the two lint
  exemptions are reviewed-stable on that branch and are what this spec builds
  against. If the PO chooses to split ROH-222 out early, the dependency shrinks to
  that merge — their call, not assumed.
- **Tier 1 (sim + previews):** everything in this slice is static UI; the in-memory
  backend preview hosts (`GroupLobbyPreviewHost` et al.) already simulate a filling
  crew and a guest lobby. Accessibility sim passes per §5. **Toggle recipe (from the
  identity-carriers session, learned the hard way):** `xcrun simctl ui <udid>`
  exposes only `increase_contrast` — Reduce Transparency must be toggled through
  Settings.app (Accessibility → Display & Text Size) or by writing
  `EnhancedBackgroundContrastEnabled` in the `com.apple.Accessibility` domain; the
  guessed `ReduceTransparencyEnabled` key silently does nothing, which renders
  exactly like "the modifier ignores the setting." Confirm the toggle actually
  flipped on a known-translucent surface before concluding anything about the cards.
- **Tier 2 (queued, no hold):** one two-device check — monogram/hue coherence
  between two live phones' lobbies, rosters, and maps for the same crew — appended
  to the existing two-phone verification session (ROH-122 family), not a new
  standing session.

## 9. Out of scope

QR-code join (PO-deferred), group-aware Live Activity, peer-focus (tap a rider to
frame them), host transfer, richer membership toasts, transport/heartbeat changes,
`GroupNavigateContainer`/HUD crew chrome (identity-carriers territory), Settings'
`DisplayNameEditor` presentation, and any `GroupRideSession` change beyond the typed
join error + the single identity derivation.

## 10. Success criteria

1. One monogram implementation; a given rider renders the same hue and monogram in
   the lobby, the roster, and on the map — pinned by a test on the single
   derivation, and eyeballed in the Tier-2 two-device check.
2. Self renders white-with-ink in every crew surface ("white = me", matching the
   puck).
3. The join code has one typographic voice; no uppercase tracked eyebrows remain in
   the group module.
4. Disabled CTAs read inert (surface + secondary + hairline) everywhere; both
   shipped disabled sites screenshotted.
5. The join screen's keyboard dismisses by drag; the entry cluster reads as one
   group; no half-screen void.
6. The code reveal animates (with a Reduce Motion branch); no other new motion.
7. One `CrewEmptyState`; the roster variant still shows the join code and share
   hint.
8. `.mapCard` exists in Theme; the lobby/roster lint exemptions are deleted; both
   cards pass Increase Contrast and Reduce Transparency sim checks.
9. Entry loading is labeled; join failures show distinct copy exactly where the
   server distinguishes them, generic otherwise; the name prompt is framed.
10. Attention semantics unchanged: badge tint warns only on a dropped rider; all
    existing roster/lobby VoiceOver labels and the ROH-81/nav invariants survive.
11. New pure logic (identity derivation, join-error mapping) is package-tested; the
    full suite and `swiftlint --strict` stay green.

## 11. Board mechanics

One child issue under ROH-45 per workstream (A–D) plus the Tier-2 verification
item, created before implementation; statuses driven per the board flow. Suggested
order: D (flow states, no visual gate) → C → A → B, with A/B behind the §7 mockup
gate; the plan stage owns sequencing and the dependency timing from §8.
