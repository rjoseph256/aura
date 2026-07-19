import SwiftUI
import AuraCore
import AuraKit

/// The host's rolling-join lobby: a prominent join code in cockpit numerals, a
/// share-link button, the crew roster as it fills live, and the "Start riding" CTA.
/// Pure presentation over `GroupRideSession` — every value it reads is
/// `public private(set)` on the session, so this view never mutates state directly
/// except through `session.startRiding()`.
struct GroupLobbyView: View {
    let session: GroupRideSession

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

            startButton
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
        }
        .padding(.horizontal, AuraTheme.Spacing.xxl)
    }

    // MARK: - Code card

    private var codeCard: some View {
        VStack(spacing: AuraTheme.Spacing.sm) {
            Text("JOIN CODE")
                .font(.caption.weight(.bold))
                .foregroundStyle(AuraTheme.textSecondary)
                .tracking(1.2)

            Text(codeText)
                .font(AuraTheme.Typography.metricCockpit(40, relativeTo: .largeTitle))
                .foregroundStyle(AuraTheme.textPrimary)
                .tracking(4)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
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
            Text(rows.isEmpty ? "Crew" : "Crew · \(rows.count) joined")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AuraTheme.textSecondary)

            if rows.isEmpty {
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
        VStack(spacing: AuraTheme.Spacing.xs) {
            Image(systemName: "person.2.wave.2")
                .font(.title2)
                .foregroundStyle(AuraTheme.textSecondary)
            Text("Waiting for your crew…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AuraTheme.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AuraTheme.Spacing.xl)
        .background(AuraTheme.surface, in: RoundedRectangle(cornerRadius: AuraTheme.Radius.lg, style: .continuous))
    }

    // MARK: - Start CTA

    private var startButton: some View {
        Button("Start riding") {
            Task { await session.startRiding() }
        }
        .buttonStyle(.ctaPrimary)
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
        GroupLobbyView(session: session)
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
