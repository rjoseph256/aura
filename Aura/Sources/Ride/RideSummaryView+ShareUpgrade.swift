// Aura/Sources/Ride/RideSummaryView+ShareUpgrade.swift
import SwiftUI
import UIKit
import AuraCore
import AuraKit
import os

/// The share-card map upgrade: the reserved row the rider sees, the attempt behind it, and the
/// latch that keeps a late-landing card from swapping out from under a presented share sheet.
/// Split out of `RideSummaryView` because that file is at its length limit, and this is the one
/// self-contained concern in it.
extension RideSummaryView {

    // MARK: The map-upgrade row

    /// One row under Share, rendered as a `ZStack` of every phase's content so it is as tall as
    /// its tallest state at **any** Dynamic Type size. A fixed `.frame(height:)` breaks at AX3+,
    /// where the offer's label wraps to two lines.
    ///
    /// Reserving matters more than it looks. Done is the only exit from this screen
    /// (`AuraApp.swift:124-135` hides the nav bar, the back button and swipe-back) and it sits
    /// below the fold, so a row that grows while a rider is scrolling toward Done lands their
    /// thumb on the offer and starts a pipeline they never asked for.
    ///
    /// Gated by the caller on `mapRequest != nil`, not on the phase: `.idle` means both "no
    /// upgrade is possible" and "none has started yet", and at ride end the presenter sits in
    /// `.idle` for the first ~0.8 s because the glance debounce is outside `attempt`. Gating on
    /// the phase would either reserve dead space on a routeless ride or pop the row in
    /// mid-entrance.
    var upgradeRow: some View {
        ZStack(alignment: .leading) {
            upgradeProgress
                .opacity(showsProgress ? 1 : 0)
                .accessibilityHidden(!showsProgress)
                .allowsHitTesting(false)
            upgradeOffer
                .opacity(showsOffer ? 1 : 0)
                .accessibilityHidden(!showsOffer)
                // Hiding is not enough, and the requirement as first written covered VoiceOver
                // only. The offer is a Button sitting directly above Done; left tappable while
                // invisible it is reachable in `.idle` and `.upgraded` too, which is precisely
                // the mis-tap this reservation exists to prevent.
                .allowsHitTesting(showsOffer)
            upgradeConfirmation
                .opacity(showsConfirmation ? 1 : 0)
                .accessibilityHidden(!showsConfirmation)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, AuraTheme.Spacing.xs)
        // Free, now that the height is reserved — and unspecified would mean a hard pop.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: upgrade.phase)
    }

    private var showsProgress: Bool { upgrade.phase == .upgradingVisible }
    private var showsConfirmation: Bool { upgrade.phase == .upgraded(confirming: true) }
    private var showsOffer: Bool {
        if case .unavailable = upgrade.phase { return true }
        return false
    }

    private var upgradeCaption: String? {
        ShareUpgradeCopy.caption(for: upgrade.phase, hasFailedARiderTap: upgrade.hasFailedARiderTap)
    }

    private var upgradeProgress: some View {
        HStack(spacing: AuraTheme.Spacing.xs) {
            ProgressView()
            Text(ShareUpgradeCopy.upgrading)
        }
        .font(.caption)
        .foregroundStyle(AuraTheme.secondaryText(contrast))
    }

    /// An offer, not an apology. Nothing is broken here — the card is finished and Share works —
    /// so there is no failure sentence, no destructive colour, no warning glyph, and explicitly
    /// none of `GroupLobbyView.startRetryRow`'s amber, which reports a failure. No SF Symbol
    /// either: `arrow.clockwise` would reintroduce the retry-after-failure reading the copy
    /// avoids. The treatment is stated rather than inherited, because inheriting the row's
    /// `.caption` + `secondaryText` chain would render a live button as small grey text that
    /// looks disabled.
    private var upgradeOffer: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.xs) {
            Button {
                tapUpgrade?.cancel()
                tapUpgrade = Task { await runUpgrade(glanceDebounce: false, origin: .riderTap) }
            } label: {
                Text(ShareUpgradeCopy.offer)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AuraTheme.accent)
                    // 44 pt of hit target, the lesson from `GroupLobbyView.swift:225-234` — worth
                    // keeping even though that row's colour is not.
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ShareUpgradeCopy.offerAccessibilityLabel)

            // Always laid out, revealed only when the rule says so. The caption sits BELOW the
            // button, so a row sized for the button alone would move Done the first time a tap
            // fails — the exact thing the reservation is for. `ShareUpgradeCopy` owns the rule;
            // re-deriving it here would put it in a target with no test bundle.
            Text(ShareUpgradeCopy.connectivityHint)
                .font(.caption)
                .foregroundStyle(AuraTheme.secondaryText(contrast))
                .opacity(upgradeCaption == nil ? 0 : 1)
                .accessibilityHidden(upgradeCaption == nil)
        }
    }

    /// Persists. A confirmation that clears itself leaves a rider who looked away unable to tell
    /// whether the tap did anything.
    private var upgradeConfirmation: some View {
        Text(ShareUpgradeCopy.confirmation)
            .font(.caption)
            .foregroundStyle(AuraTheme.secondaryText(contrast))
    }

    // MARK: The attempt

    /// One upgrade attempt: the glance debounce, then the presenter's timing rules wrapped around
    /// the raster fetch and the re-render.
    ///
    /// **The 0.8 s sleep stays OUTSIDE `upgrade.attempt`.** Inside it, the 300 ms show-delay would
    /// run during the sleep and "Adding your map…" would appear at t+0.3 s — a hard insert in the
    /// middle of the entrance, on every ride end. That is verbatim the rev-3 rejection in the
    /// ROH-155 record: "the one drawing operation the rider actually sees during the entrance, and
    /// it was the one left ungated."
    func runUpgrade(glanceDebounce: Bool, origin: AttemptOrigin) async {
        guard let content = cardContent, let fileStore = cardFileStore,
              let request = mapRequest else { return }
        let title = cardTitle
        if glanceDebounce {
            // Three jobs. The third is the one that makes this delay load-bearing, and it
            // was written down nowhere until ROH-155 went looking for a reason to delete it.
            //
            // 1. Ride-end: the HUD prefetch fired at +0.7 s and this request dedups onto it.
            // 2. History: keeps a warm hit's upgrade render — a 1080×1350 main-actor
            //    ImageRenderer pass — out of the entrance animation. Ride-end can't warm-hit:
            //    `cacheKey` carries the rideID and the ride has never been rendered.
            // 3. It debounces committing the process-wide pipeline slot. `slot.run` has NO
            //    cancellation point — both its awaits go through `withCheckedContinuation`
            //    and the pipeline task is unstructured — so a cancelled caller neither
            //    returns nor frees the slot. This sleep plus the guard below is the only
            //    thing stopping a sub-second History glance from committing the single slot
            //    to a ride nobody is looking at; the ride the rider IS looking at then
            //    queues behind it. Reproduced at three glances: the on-screen ride resolved
            //    at 2.18 s instead of 1.36 s, because the post-release wake-up is a
            //    thundering herd rather than a queue.
            //
            // So ride-end and History want opposite policies here — asking early is pure
            // insurance for one ride, and a ghost queue for unbounded glances. Any change
            // that treats the two paths alike is wrong in one of them. ROH-155 was closed
            // after three design revisions failed on exactly that; the analysis is in
            // docs/superpowers/specs/2026-07-31-share-prefetch-ownership-design.md.
            try? await Task.sleep(for: .seconds(0.8))
            // Load-bearing with job 3: this is what turns a glance into no pipeline at all.
            guard !Task.isCancelled else { return }
        }
        // Started after the debounce on purpose: the question this log answers is how long an
        // upgrade takes, not how long the app waited before asking.
        let started = ContinuousClock.now
        var outcome = ShareUpgradeResult.stoppedWaiting
        await upgrade.attempt(origin: origin) {
            let result = await attemptUpgrade(content: content, fileStore: fileStore,
                                              title: title, request: request)
            outcome = result
            return result
        }
        let elapsed = started.duration(to: .now).components
        let millis = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
        Self.log.notice("""
            Share map upgrade (\(Self.label(origin), privacy: .public)): \
            \(Self.label(outcome), privacy: .public) in \(millis) ms
            """)
    }

    /// The body of one attempt: fetch the raster, re-render the card, hand it to the swap latch.
    private func attemptUpgrade(content: ShareCardContent, fileStore: ShareCardFileStore,
                                title: String, request: ShareMapRequest) async -> ShareUpgradeResult {
        switch await shareMap.provider.raster(for: request) {
        case .rejected:
            return .rejected
        case .stoppedWaiting:
            return .stoppedWaiting
        case .map(let raster):
            // Kept, and it applies to both origins. On the `.first` path this task IS the view's
            // `.task`, so a dismissal cancels it and the guard stops a 1080×1350 main-actor
            // ImageRenderer pass running during the pop-to-Home animation. A rider tap runs in
            // `tapUpgrade`, which `.onDisappear` cancels for exactly the same reason — nothing
            // else ever would, since that task is not `.task`'s child.
            guard !Task.isCancelled else { return .stoppedWaiting }
            // NOT `generation += 1` followed by a read: a @State read-after-write outside `body`
            // is not a documented guarantee, and a stale read would overwrite generation 0 — the
            // fallback card a live share sheet may still be reading.
            let next = generation + 1
            generation = next
            // A render failure is `.stoppedWaiting`, not `.rejected`. The raster is cached by now,
            // so a fresh attempt would warm-hit and fail at the same renderer, deterministically.
            // `.mayRejoin` still offers the rider the button; it just refuses to promise the next
            // press is a new fetch.
            guard let upgraded = await RideCardRenderer.make(content, mapImage: raster, title: title,
                                                             writeTo: fileStore.url(generation: next))
            else { return .stoppedWaiting }
            applyOrDeferUpgrade(upgraded)
            return .gotMap
        }
    }

    /// `nonisolated` for the same reason `RideCardRenderer`'s is: this view is main-actor
    /// isolated and `Logger` is Sendable.
    private nonisolated static let log = Logger(subsystem: "app.aura.ios", category: "ShareCard")

    private nonisolated static func label(_ origin: AttemptOrigin) -> String {
        switch origin {
        case .first:    return "first"
        case .riderTap: return "tap"
        }
    }

    private nonisolated static func label(_ result: ShareUpgradeResult) -> String {
        switch result {
        case .gotMap:         return "map"
        case .rejected:       return "rejected"
        case .stoppedWaiting: return "stopped-waiting"
        }
    }

    // MARK: Share-sheet swap latch

    /// Assign the upgraded card, unless a share sheet is up — in which case hold it until the
    /// sheet is gone.
    ///
    /// `ShareLink`'s `item:` is what the presented `UIActivityViewController` was built from.
    /// Changing it mid-presentation is the case the spec flagged as a risk and never verified;
    /// the 2026-07-31 device pass then watched a presented sheet dismiss itself the moment a
    /// swap landed, with a no-swap control run holding its sheet open across the same window.
    /// Deferring costs nothing when no sheet is open, which is the overwhelmingly common path
    /// (the upgrade resolves ~1.5 s after the summary appears on wifi, usually before a rider
    /// can even reach the button).
    private func applyOrDeferUpgrade(_ upgraded: RideShareImage) {
        // Two questions, and the second one is ROH-185 — which ROH-178 named as the half it did
        // not fix: "the presentation wait is one-shot and bounded at 2 s, so a sheet that presents
        // later than that leaves shareSheetUp false."
        //
        // The latch answers "did the rider tap Share", and it is set before there is anything to
        // observe. It stops answering once `beginShareSheetWatch` gives up waiting at 20 × 100 ms,
        // which a cold first share can outlast — and assigning under a live sheet is what the
        // 2026-07-31 device pass watched dismiss one. So ask UIKit again at the moment of
        // assignment, when there IS something to observe.
        //
        // `isPresentingShareSheet`, never a broader predicate. ROH-178 measured the naive reading
        // (`presentedViewController != nil`) at chain depth 1 on the History path with no sheet
        // tapped, because `RideSummaryView` is itself the presented sheet there — which would
        // defer every upgrade for the summary's whole lifetime. Widening this to "any modal"
        // reintroduces that, and it is a tempting mistake: an alert or an incoming call really
        // would be safer to defer under. Not safe enough to pay for it on every History ride.
        guard !shareSheetUp, !SharePresentation.isPresentingShareSheet else {
            deferredUpgrade = upgraded
            // A deferral nobody drains is worse than the swap: the row would say "Map added"
            // over a card with no map, permanently. The latch already has a releaser; a sheet
            // that came up after the latch gave up does not, so start one. No-ops when the
            // latch is up.
            beginShareSheetWatch()
            return
        }
        shareImage = upgraded
    }

    /// Watches the share sheet's lifetime and releases any held upgrade when it ends.
    ///
    /// Two entry conditions, deliberately. The Share tap calls it *predictively* — no sheet exists
    /// yet, which is why the first loop is a bounded wait for one to appear. `applyOrDeferUpgrade`
    /// calls it *observationally*, having just read a live sheet, so that wait is satisfied on
    /// the first poll.
    ///
    /// It polls `presentedViewController` because SwiftUI gives `ShareLink` no presentation
    /// binding to observe — there is no callback, and the sheet is a system-owned
    /// `UIActivityViewController`. The poll stops as soon as the sheet closes, so it costs
    /// nothing outside the seconds one is actually up.
    func beginShareSheetWatch() {
        guard !shareSheetUp else { return }
        shareSheetUp = true
        Task {
            // Wait for presentation (bounded — if the sheet never appears, don't hold the
            // upgrade hostage; a rider who somehow never got a sheet still gets the map card).
            var appeared = false
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
                if SharePresentation.isPresentingShareSheet { appeared = true; break }
            }
            if appeared {
                while SharePresentation.isPresentingShareSheet, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            shareSheetUp = false
            if let deferredUpgrade {
                shareImage = deferredUpgrade
                self.deferredUpgrade = nil
            }
        }
    }
}
