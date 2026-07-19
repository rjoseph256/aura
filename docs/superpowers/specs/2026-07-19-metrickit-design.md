# MetricKit adoption — design

**Date:** 2026-07-19
**Status:** approved (pending adversarial review)
**Linear:** to be filed before implementation

## Why

Aura has no production telemetry. Today's question — "what did a 32-minute group ride cost in
battery?" — could not be answered from the Mac at all; the only source was Settings → Battery on
the phone. More broadly, three prod-dead defects shipped green this month because nothing observed
the app in the field.

MetricKit gives daily aggregated performance metrics and crash/hang diagnostics from real devices.

### What MetricKit does not do

Stated plainly so nobody builds on a false expectation:

- **It does not report battery drain.** There is no percentage or mAh in the API. It reports
  proxies — cumulative CPU time, GPU time, background *location* time, network bytes, display
  time. "That ride cost 12%" remains a Settings → Battery question.
- **Payloads are daily aggregates**, delivered roughly every 24 hours. A single ride is not
  isolated. Per-interval attribution would require custom `mxSignpost` instrumentation, which is
  explicitly **out of scope** here.
- **Backfill is limited.** `pastPayloads` returns reports generated since the last allocation of
  `MXMetricManager.shared`. Data before first adoption does not exist, and payloads dropped on the
  floor are not redelivered.

## Decisions

| Decision | Choice |
| -- | -- |
| Scope | Broad daily telemetry — the whole `MXMetricPayload` |
| Diagnostics | Included: `MXDiagnosticPayload` (crash, hang, CPU exception, disk write) |
| Destination | Persist locally, upload to Supabase |
| Audience | All users, **opt-in toggle, default off** |
| Identity | Buffer locally, upload only when an authenticated session exists |
| Per-ride signposts | Out of scope |

## Architecture

Three layers, following the existing seam pattern (`WorkoutWriting`, `HapticPlaying`,
`GroupLocationSink`). The split is deliberate: the app target holds only what cannot be tested,
because untestable app-target logic is exactly what let this month's three live-layer bugs ship
with a green suite.

### AuraCore — pure, fully unit-tested

- **`MetricsEnvelope`** — Codable wrapper: `id`, `kind` (`metric` | `diagnostic`), `capturedAt`,
  `appVersion`, `osVersion`, `deviceModel`, and the untouched MetricKit JSON.
- **`MetricsRetention`** — pure policy: which staged files to prune, by age and by count.
- **`MetricsFileName`** — encode/parse a staged file's name, so listing and ordering are testable
  without a filesystem.

### AuraKit — orchestration, tested against fakes

- **`MetricsStaging`** — write an envelope, list pending oldest-first, delete one, prune. The
  directory is injected so tests run against a temp dir.
- **`MetricsFlusher`** — upload pending files through a `MetricsUploading` seam; delete only on
  confirmed success; classify failures (below); prune afterwards.

### App target — thin

- **`MetricsSubscriber`** — `NSObject` / `MXMetricManagerSubscriber`. Both `didReceive` callbacks
  do exactly one thing: write raw `jsonRepresentation()` through `MetricsStaging`, then return.
  No parsing, no network.
- **`SupabaseMetricsUploader`** — the `MetricsUploading` implementation.

### Flow

1. `AuraApp.init()` — if consent is on, register the subscriber and drain `pastPayloads` and
   `pastDiagnosticPayloads`.
2. Payload arrives → envelope → written to disk synchronously → callback returns.
3. App foregrounds with an authenticated session → `MetricsFlusher.flush()`.
4. Prune per retention policy.

**The callback never uploads and never parses.** Its only job is getting bytes on disk before
anything can fail. Network, auth, and encoding failures then act on a durable file, so failure
costs a retry rather than the payload.

Consequence, named rather than discovered later: a rider who opts in but never signs in
accumulates files indefinitely. That is why `MetricsRetention` is a real component.

## Data model

New migration `0017_app_metrics.sql`:

```sql
create table public.app_metrics (
  id uuid primary key,                        -- client-generated
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('metric','diagnostic')),
  captured_at timestamptz not null,
  app_version text,
  os_version text,
  device_model text,
  payload jsonb not null,
  created_at timestamptz not null default now()
);
```

RLS enabled; insert and select both gated on `user_id = (select auth.uid())`, **plus explicit
GRANTs** — on this project RLS policies alone are not sufficient (learned in Wave 4 SP1).

Two choices worth their rationale:

- **Client-generated `id` + `on conflict do nothing`.** A retry after a response we never saw
  cannot duplicate a payload. Together with delete-only-on-confirmed-success this makes the flush
  safe to repeat.
- **Raw `payload` as jsonb**, not shredded into columns. New MetricKit fields need no migration,
  and anything we failed to anticipate is still queryable over MCP.

Server-side pruning of rows older than **90 days** via the existing `pg_cron`, since payloads
accrue daily forever.

## Consent and privacy

- **`shareDiagnostics`** on `SettingsStore`, default `false`, **device-local** — added to `Key`
  but *not* to `syncedKeys`. This follows `saveToHealth`, which is deliberately excluded from
  iCloud sync; permission-adjacent toggles stay per-device.
- A Settings row with plain disclosure: what is collected (app performance and crash reports, no
  ride or location data), where it goes, and that it is off unless enabled.
- **Off → on:** register the subscriber.
- **On → off:** unregister **and delete every staged file.** Data the rider declined to share must
  not sit on disk awaiting a future opt-in.

`PrivacyInfo.xcprivacy` in the app target: `NSPrivacyTracking = false`; collected types cover
performance and crash data; marked *linked to the user* (we attach `user_id`) and used for App
Functionality, not tracking.

The disclosure claims no location data is collected. `cumulativeBackgroundLocationTime` is a
*duration*, not coordinates, so this holds — but it is a claim that must stay true if signposts
are added later.

## Error handling

The one unrecoverable path is a write failure inside `didReceive`: MetricKit will not redeliver,
so the payload is lost. Mitigation is structural — the callback does a single `Data.write` and
nothing else, minimising what can fail. Log and continue.

Everything downstream is recoverable, but only if failures are classified:

| Failure | Response |
| -- | -- |
| Network / 5xx / timeout | **Transient** — leave file, stop batch, retry next foreground |
| Not signed in | Skip flush entirely, files untouched |
| File unreadable or undecodable | **Permanent** — drop that file, continue batch |
| Server rejects payload (4xx) | **Permanent** — drop that file, continue batch |

The transient/permanent split exists because of stop-on-first-failure. Without it, one corrupt
file at the head of the queue blocks every future upload permanently — a poison pill that presents
as "telemetry silently stopped working." Stopping the batch is correct for transient failures and
wrong for permanent ones.

Retention is bounded by **both** age and count, so a signed-out opted-in rider cannot fill the
container: **keep at most 50 staged files, and drop anything older than 30 days**, whichever binds
first. At roughly one metric payload per day plus occasional diagnostics, 50 files is comfortably
more than a normal backlog and still a hard ceiling on a device that never signs in. These are the
values `MetricsRetention` is specified and tested against; changing them is a test change, not a
judgement call at implementation time.

## Testing

**AuraCore (pure):** envelope round-trip; retention at both the age and count caps; filename
encode/parse.

**AuraKit `MetricsFlusher`** against a fake uploader and temp directory — this is where the real
behaviour lives:

- uploads pending oldest-first
- deletes only after confirmed success
- transient failure leaves the file and halts the batch
- permanent failure drops the file and continues
- no auth is a no-op, files intact
- retry reuses the same `id` (idempotency)
- prune runs after flush

**App target:** roughly ten lines that cannot be unit-tested — subscriber registration and the
Supabase insert. Verified by hand.

### Verification without waiting 24 hours

Xcode *Debug → Simulate MetricKit Payloads* delivers a synthetic metric payload on demand. The
end-to-end check is then a Supabase query over MCP confirming the row landed — a materially better
loop than the on-device UI verification this branch has needed.

**Honest gap:** that simulator covers metric payloads, not diagnostics. Verifying the crash path
realistically means deliberately crashing a build and waiting for delivery. Diagnostics ship
**unproven** until a real crash exercises them, and should be reported that way rather than
implied verified.

## Out of scope

- Custom `mxSignpost` per-ride attribution
- In-app viewer for collected metrics (Supabase + MCP is the read path)
- dSYM upload and automated symbolication of crash call stacks
- `BGProcessingTask` background flush — foreground flush suffices for daily payloads; adoptable
  later without restructuring
- Xcode Organizer integration (works only for TestFlight/App Store builds; no code involved)
