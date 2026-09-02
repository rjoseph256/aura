import SwiftUI
import AuraCore
import AuraKit

/// The rolling-join lobby, shared by both roles: a prominent join code in cockpit
/// numerals, a share-link button, and the crew roster as it fills live. The bottom CTA
/// slot splits by role — the host gets "Start riding" (with an inline retry row on
/// failure); a guest gets a calm "waiting for the host" status plus Leave. Pure
/// presentation over `GroupRideSession` — every value it reads is `public private(set)`
/// on the session, so this view never mutates state directly except through
/// `session.startRiding()` and `session.leave()`.
struct GroupLobbyView: View {
    let session: GroupRideSession
    /// The host's destination by name, for the kind line (ROH-114 D5.4). Nil for an open ride and
    /// nil for every guest, who joined by code and never had a `Place`.
    let placeName: String?
    /// Passed in rather than read from `SettingsStore` in this view on purpose: the store is
    /// injected only at the app root (`AuraApp`), so an `@Environment` lookup here would compile
    /// and then trap at runtime in both previews below. No defaults on either of these, so a new
    /// call site has to say what it means instead of silently inheriting imperial.
    let isImperial: Bool

    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    /// Rows built straight from `session.peers` + `session.nameMap` — the lobby has no
    /// progress/distance yet, so this is simpler than `GroupRosterViewData.rows`
    /// (which is for the live map, where distance-to-peer matters).
    private var rows: [LobbyRosterRow] {
        session.peers.map { peer in
            LobbyRosterRow(id: peer.userID,
                          name: DisplayName.forDisplay(session.nameMap[peer.userID] ?? peer.displayName))
        }
    }

    private var shareURL: URL? {
        guard let code = session.joinCode else { return nil }
        return URL(string: "aura://join?code=\(code.rawValue)")
    }

    /// The host's display name for the guest-facing waiting copy. Falls back to "the host"
    /// when the roster fetch hasn't resolved a name yet (or `hostID` itself is unset).
    private var hostName: String {
        guard let hostID = session.hostID, let name = session.nameMap[hostID] else { return "the host" }
        return DisplayName.forDisplay(name)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, AuraTheme.Spacing.xl)

            codeCard
                .padding(.top, AuraTheme.Spacing.xxl)
                .padding(.horizontal, AuraTheme.Spacing.xxl)

            if let shareURL {
                ShareLink(item: shareURL) {
                    Label("Share link", systemImage: "square.and.arrow.up")
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                }
                .buttonStyle(.ctaSecondary)
                .padding(.top, AuraTheme.Spacing.lg)
                .padding(.horizontal, AuraTheme.Spacing.xxl)
            }

            rosterSection
                .padding(.top, AuraTheme.Spacing.xxl)
                .padding(.horizontal, AuraTheme.Spacing.xxl)

            Spacer(minLength: AuraTheme.Spacing.lg)

            ctaSection
                .padding(.horizontal, AuraTheme.Spacing.xxl)
                .padding(.bottom, AuraTheme.Spacing.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AuraTheme.background.ignoresSafeArea())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: rows.count)
        // Subscribe the host to the live layer while still in the lobby so joiners appear
        // (their first position drives a roster refresh that names them) and the seed
        // roster shows everyone who has already joined. beginLiveSession is idempotent, so
        // the later `.riding` `.task` calling it again is a safe no-op.
        .task { await session.beginLiveSession() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: AuraTheme.Spacing.xs) {
            Text("Ride together")
                .font(.title2.weight(.bold))
                .foregroundStyle(AuraTheme.textPrimary)
            Text("Share your code to get your crew rolling")
                .font(.subheadline)
                .foregroundStyle(AuraTheme.textSecondary)
                .multilineTextAlignment(.center)

            // Which sort of ride this is (D5.4). Without it the lobby renders identically
            // whether a guest is about to be navigated 8 km or turned loose, and they have no
            // other signal — they got here by typing a code.
            if let kindLine = GroupRideSubtitle.text(kind: session.rideKind,
                                                     placeName: placeName,
                                                     distanceMeters: session.route?.distanceMeters,
                                                     isImperial: isImperial) {
                Text(kindLine)
                    .font(.subheadline)
                    .foregroundStyle(AuraTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, AuraTheme.Spacing.xs)
            }
        }
        .padding(.horizontal, AuraTheme.Spacing.xxl)
    }

    // MARK: - Code card

    private var codeCard: some View {
        VStack(spacing: AuraTheme.Spacing.sm) {
            Text("Join code")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AuraTheme.textSecondary)

            JoinCodeText(code: codeText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AuraTheme.Spacing.xl)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AuraTheme.Radius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AuraTheme.Radius.xl, style: .continuous)
                .strokeBorder(AuraTheme.hairline(contrast))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Join code, \(spokenCode)")
    }

    private var codeText: String { session.joinCode?.rawValue ?? "········" }

    /// Spells the code letter-by-letter so VoiceOver doesn't try to pronounce it as a word.
    private var spokenCode: String {
        guard let code = session.joinCode?.rawValue else { return "loading" }
        return code.map(String.init).joined(separator: " ")
    }

    @ViewBuilder private var cardBackground: some View {
        if AuraTheme.prefersOpaqueSurface(reduceTransparency: reduceTransparency, contrast) {
            AuraTheme.surface
        } else {
            AuraTheme.surface.opacity(0.9).background(.ultraThinMaterial)
        }
    }

    // MARK: - Roster

    private var rosterSection: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.md) {
            Text(LobbyCrewLabel.text(totalRows: rows.count))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AuraTheme.textSecondary)

            if LobbyCrewLabel.isWaiting(totalRows: rows.count) {
                emptyRosterState
            } else {
                VStack(spacing: AuraTheme.Spacing.xs) {
                    ForEach(rows) { row in
                        LobbyRosterRowView(row: row)
                        if row.id != rows.last?.id {
                            Divider().overlay(AuraTheme.border)
                        }
                    }
                }
                .padding(.horizontal, AuraTheme.Spacing.lg)
                .padding(.vertical, AuraTheme.Spacing.sm)
                .background(AuraTheme.surface, in: RoundedRectangle(cornerRadius: AuraTheme.Radius.lg, style: .continuous))
            }
        }
    }

    private var emptyRosterState: some View {
        CrewEmptyState(variant: .lobby)
            .background(AuraTheme.surface, in: RoundedRectangle(cornerRadius: AuraTheme.Radius.lg, style: .continuous))
    }

    // MARK: - Role-split CTA

    /// Host keeps the "Start riding" CTA (with an inline retry row on failure); a guest
    /// gets a calm waiting state plus a Leave button. Both branches share the roster/code/
    /// share-link chrome above — only this bottom slot differs by role.
    @ViewBuilder private var ctaSection: some View {
        if session.isHost {
            VStack(spacing: AuraTheme.Spacing.sm) {
                startButton
                if session.startFailed {
                    startRetryRow
                }
            }
        } else {
            guestWaitingSection
        }
    }

    private var startButton: some View {
        Button("Start riding") {
            Task { await session.startRiding() }
        }
        .buttonStyle(.ctaPrimary)
    }

    /// Inline error-recovery row shown under the Start button when the host's last attempt
    /// failed server-side. Amber warning treatment mirrors `GPSSignalChip`'s escalated-caution
    /// styling elsewhere in the app, scaled down to a card row instead of a HUD chip.
    ///
    /// The message and the Retry button are deliberately NOT combined into one accessibility
    /// element: combining the whole row would swallow the Button into an opaque, non-activatable
    /// label, leaving a VoiceOver user with no way to recover from a failed start. Only the
    /// message (icon + text) is combined; the Button keeps its own default accessible identity
    /// ("Retry", `.isButton` trait) so it stays independently focusable and activatable.
    private var startRetryRow: some View {
        HStack(spacing: AuraTheme.Spacing.sm) {
            Label("Couldn't start", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AuraTheme.warning)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Couldn't start the ride")
            Spacer(minLength: AuraTheme.Spacing.sm)
            Button("Retry") {
                Task { await session.startRiding() }
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(AuraTheme.warning)
            // No CTAButtonStyle variant keeps the warning color (they're all accent/onAccent/
            // onDestructive), so the 44pt HIG minimum is met directly rather than by adopting
            // a style — same fix LocationPermissionView applies to its own sub-40pt tertiary
            // button: a minHeight plus a rectangular content shape so the whole padded area,
            // not just the glyph-tight text, is tappable.
            .padding(.horizontal, AuraTheme.Spacing.sm)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, AuraTheme.Spacing.lg)
        .padding(.vertical, AuraTheme.Spacing.sm)
        .background(AuraTheme.warning.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: AuraTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AuraTheme.Radius.md, style: .continuous)
                .strokeBorder(AuraTheme.warning.opacity(0.55))
        )
    }

    /// Guest lobby state: no Start authority, so the CTA slot becomes a calm status readout
    /// (styled like `emptyRosterState`'s surface card, not a disabled button) plus a
    /// low-emphasis Leave action. Leave never routes through `.ended` — it pops this pushed
    /// entry straight back home (see the file-header note and Task 8's leave semantics).
    private var guestWaitingSection: some View {
        VStack(spacing: AuraTheme.Spacing.md) {
            HStack(spacing: AuraTheme.Spacing.sm) {
                Image(systemName: "hourglass")
                Text("Waiting for \(hostName) to start…")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AuraTheme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AuraTheme.Spacing.md)
            .background(AuraTheme.surface, in: RoundedRectangle(cornerRadius: AuraTheme.Radius.lg, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Waiting for \(hostName) to start the ride")

            Button("Leave") {
                Task {
                    await session.leave()
                    router.pop()
                }
            }
            .buttonStyle(.ctaTertiary)
        }
    }
}

// MARK: - Lobby roster row (no distance — pre-ride)

private struct LobbyRosterRow: Identifiable, Equatable {
    let id: UUID
    let name: String
}

private struct LobbyRosterRowView: View {
    let row: LobbyRosterRow

    private var initial: String {
        String(row.name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    var body: some View {
        HStack(spacing: AuraTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(AuraTheme.accent)
                    .frame(width: 32, height: 32)
                Text(initial)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(AuraTheme.onAccent)
            }
            Text(row.name)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(AuraTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, AuraTheme.Spacing.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name) joined")
    }
}

// MARK: - Preview

#Preview("Lobby — crew filling in") {
    GroupLobbyPreviewHost()
        .environment(AppRouter())
        .preferredColorScheme(.dark)
}

#Preview("Lobby — guest waiting") {
    GroupLobbyGuestPreviewHost()
        .environment(AppRouter())
        .preferredColorScheme(.dark)
}

/// Drives a real `GroupRideSession` against in-memory fakes so the preview needs no
/// network: signs in as host, creates a ride, joins two more identities (sharing the
/// same in-memory store, so `roster()` resolves their names), then `ingest`s a
/// position for each — the public path a live broadcast would take — so the roster
/// fills in without ever starting the live ticker.
private struct GroupLobbyPreviewHost: View {
    private let hostBackend: InMemoryGroupRideBackend
    @State private var session: GroupRideSession

    init() {
        let hostBackend = InMemoryGroupRideBackend()
        self.hostBackend = hostBackend
        _session = State(initialValue: GroupRideSession(
            backend: hostBackend, transport: InMemoryRideSessionTransport(),
            displayNameProvider: { "Jamie Rivera" }))
    }

    var body: some View {
        GroupLobbyView(session: session, placeName: "Blue Bottle", isImperial: true)
            .task {
                let route = Route(id: UUID(),
                                  origin: Coordinate(latitude: 40.44, longitude: -79.99),
                                  destination: Coordinate(latitude: 40.46, longitude: -79.95),
                                  waypoints: [], geometry: [], profile: .fastest,
                                  distanceMeters: 8_000, estimatedDurationSeconds: 1_800,
                                  elevationGainMeters: 60)
                try? await hostBackend.signIn(idToken: "preview", nonce: "preview", displayName: "Jamie Rivera")
                await session.create(route: route)
                guard let code = session.joinCode else { return }

                for name in ["Priya", "Marcus"] {
                    let peerBackend = InMemoryGroupRideBackend(sharing: hostBackend)
                    try? await peerBackend.signIn(idToken: "preview-\(name)", nonce: "preview", displayName: name)
                    guard let userID = try? await peerBackend.currentUserID(),
                          (try? await peerBackend.joinRide(code: code)) != nil else { continue }
                    await session.ingest(.position(LivePositionPayload(
                        userID: userID, coordinate: route.origin, progressMeters: 0,
                        recordedAt: Date(), motionState: .moving)))
                }
            }
    }
}

/// Same in-memory setup as `GroupLobbyPreviewHost`, but the rendered session belongs to
/// a second identity that JOINS rather than creates — `isHost` is false, so the lobby
/// renders the guest's "Waiting for … to start" state and Leave button instead of the
/// Start CTA. The host's own session runs off-screen only to create the ride and seed
/// its display name into the shared store for `hostName` to resolve.
private struct GroupLobbyGuestPreviewHost: View {
    private let hostBackend: InMemoryGroupRideBackend
    private let guestBackend: InMemoryGroupRideBackend
    @State private var guestSession: GroupRideSession

    init() {
        let hostBackend = InMemoryGroupRideBackend()
        self.hostBackend = hostBackend
        let guestBackend = InMemoryGroupRideBackend(sharing: hostBackend)
        self.guestBackend = guestBackend
        _guestSession = State(initialValue: GroupRideSession(
            backend: guestBackend, transport: InMemoryRideSessionTransport(),
            displayNameProvider: { "Priya" }))
    }

    var body: some View {
        GroupLobbyView(session: guestSession, placeName: nil, isImperial: true)
            .task {
                let route = Route(id: UUID(),
                                  origin: Coordinate(latitude: 40.44, longitude: -79.99),
                                  destination: Coordinate(latitude: 40.46, longitude: -79.95),
                                  waypoints: [], geometry: [], profile: .fastest,
                                  distanceMeters: 8_000, estimatedDurationSeconds: 1_800,
                                  elevationGainMeters: 60)
                try? await hostBackend.signIn(idToken: "preview-host", nonce: "preview", displayName: "Jamie Rivera")
                let hostSession = GroupRideSession(
                    backend: hostBackend, transport: InMemoryRideSessionTransport(),
                    displayNameProvider: { "Jamie Rivera" })
                await hostSession.create(route: route)
                guard let code = hostSession.joinCode, let hostID = hostSession.hostID else { return }

                try? await guestBackend.signIn(idToken: "preview-guest", nonce: "preview", displayName: "Priya")
                await guestSession.join(code: code)

                // `GroupLobbyView(session: guestSession)` mounts above as soon as this preview
                // host's body is evaluated — before `join(code:)` above completes — so the
                // view's own `.task { await session.beginLiveSession() }` can run while
                // `guestSession`'s inner `rideSession` is still nil and no-op (same shape as the
                // production race that `.task` is written to tolerate, except production never
                // mounts `GroupLobbyView` before `session.phase == .lobby`, so it never hits this
                // window). Seed `nameMap` explicitly instead, exactly the way `GroupLobbyPreviewHost`
                // seeds its peer names above: an `ingest(.position(...))` for the host's userID,
                // issued only after `join(code:)` has set `rideSession`, triggers `refreshRoster()`
                // or resolves the host's display name from the shared in-memory store so the
                // guest's "Waiting for Jamie Rivera to start…" label actually renders the name
                // instead of falling back to "the host".
                await guestSession.ingest(.position(LivePositionPayload(
                    userID: hostID, coordinate: route.origin, progressMeters: 0,
                    recordedAt: Date(), motionState: .moving)))
            }
    }
}
