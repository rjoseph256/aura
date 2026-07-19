import SwiftUI
import AuraCore
import AuraKit

/// Owns the group-ride session for one navigation-stack entry: constructs the live
/// `GroupRideSession` around the app's real Supabase backend/transport, drives the
/// create-or-join call the entry asks for, and switches on `session.phase` to present
/// the right screen. `.riding` renders `GroupNavigateContainer`, which composes the crew
/// chrome (roster/toasts/pill) over the existing solo `NavigateHUDView`.
struct GroupRideFlowView: View {
    let entry: GroupRideEntry

    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    @State private var session: GroupRideSession
    @State private var displayNameStore = DisplayNameStore(backend: SupabaseGroupRideBackend())
    /// Distinguishes a guest/host who actually entered the riding container (rode, then the
    /// ride ended — keep the solo HUD running) from one who never got past the lobby/join
    /// before the ride ended (show a dedicated ended surface instead of a blank/wrong screen).
    /// Set once, in `ridingContainer`'s `.task`, the first time this view enters `.riding`.
    @State private var didEnterRiding = false

    init(entry: GroupRideEntry) {
        self.entry = entry
        _session = State(initialValue: GroupRideFlowView.makeSession())
    }

    var body: some View {
        content
            .task { await invokeEntry() }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task { await session.reconcileFromStatus() }
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .idle:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AuraTheme.background.ignoresSafeArea())

        case .needsDisplayName:
            // No wrapping NavigationStack here: this whole view is already a pushed
            // destination inside the app's root NavigationStack, and nesting a second
            // NavigationStack inside a pushed column makes SwiftUI's path reconciliation
            // (NavigationColumnState.boundPathChange) throw swift_unexpectedError and
            // crash the app. DisplayNameEditor only needs *a* navigation context for its
            // `.navigationTitle`, which the root stack already provides.
            DisplayNameEditor(store: displayNameStore) {
                Task { await invokeEntry() }
            }

        case .lobby:
            GroupLobbyView(session: session)

        // A rider who actually entered `.riding` and whose ride later ends (host-end, D9)
        // must NOT have this view torn down — the rider's in-progress solo navigation
        // (owned by the `RideSessionCoordinator` inside `GroupNavigateContainer`'s
        // `NavigateHUDView`) would be abandoned along with it. `GroupNavigateContainer`
        // itself reads `session.phase` to hide the crew chrome once `.ended`, while the
        // solo HUD underneath keeps running — `ridingContainer` handles both `.riding`
        // and that "rode, then ended" case. A ride that ends while the rider is still in
        // the lobby/join flow (never entered `.riding`) never had a HUD to preserve, so
        // it gets a dedicated ended surface instead.
        case .riding:
            ridingContainer
        case .ended:
            if didEnterRiding {
                ridingContainer
            } else {
                endedLobbySurface
            }

        case .createFailed:
            dismissMessage(
                title: "Couldn't start the group ride — try again.",
                systemImage: "person.2.slash"
            )

        case .routeUnavailable:
            dismissMessage(
                title: "Couldn't load this ride's route.",
                systemImage: "exclamationmark.triangle"
            )

        case .joinFailed:
            dismissMessage(
                title: "Couldn't join — double-check the code with your host.",
                systemImage: "person.crop.circle.badge.xmark"
            )
        }
    }

    // MARK: - Riding / ended-while-riding

    /// `.riding`, plus the "rode, then the ride ended" case of `.ended` (`didEnterRiding`
    /// true) — see the phase switch above for why those two share a screen. `.task`'s
    /// first-run flips `didEnterRiding` before awaiting `beginLiveSession()`, so a
    /// same-tick ended transition (a ride that ended the instant it was joined) still
    /// counts as "entered riding" once this container has mounted. `.task` is keyed to
    /// this view's identity, not to phase, so the ended transition doesn't restart it.
    @ViewBuilder private var ridingContainer: some View {
        if session.route != nil {
            GroupNavigateContainer(session: session)
                .task {
                    didEnterRiding = true
                    await session.beginLiveSession()
                }
        } else {
            // Guarded per the brief: `.riding` with no route is unreachable in
            // practice (create/join both set `route` before this phase), but
            // render something sane rather than a blank screen.
            dismissMessage(
                title: "Couldn't load this ride's route.",
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    // MARK: - Ended from lobby/join

    /// `.ended` reached without ever entering `.riding` — e.g. the host ends the ride
    /// while a guest is still on the lobby/join screen. There's no solo HUD underneath to
    /// preserve here, so this is a real terminal screen rather than a pass-through.
    private var endedLobbySurface: some View {
        dismissMessage(title: "This ride has ended.", systemImage: "flag.checkered")
    }

    // MARK: - Entry invocation

    /// Drives the entry's create/join call. Re-invoked after a display-name save so
    /// the original intent (create this route / join this code) completes once a
    /// valid name exists.
    private func invokeEntry() async {
        switch entry {
        case let .create(route):
            await session.create(route: route)
        case let .join(code):
            await session.join(code: code)
        }
    }

    // MARK: - Dismiss-with-message

    private func dismissMessage(title: String, systemImage: String) -> some View {
        VStack(spacing: AuraTheme.Spacing.lg) {
            Spacer()
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(AuraTheme.textSecondary)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(AuraTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AuraTheme.Spacing.xxl)
            Spacer()
            Button("Back") {
                router.pop()
            }
            .buttonStyle(.ctaPrimary)
            .padding(.horizontal, AuraTheme.Spacing.xxl)
            .padding(.bottom, AuraTheme.Spacing.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AuraTheme.background.ignoresSafeArea())
    }

    // MARK: - Session construction

    /// Builds the session against the app's real Group Rides backend/transport
    /// (both `nonisolated struct`s with parameterless live defaults — see
    /// `SupabaseGroupRideBackend`/`SupabaseRideSessionTransport`), reading the
    /// crew display name from the same `DisplayNameStore.crewDisplayNameKey`
    /// UserDefaults key `DisplayNameStore` owns.
    @MainActor
    private static func makeSession() -> GroupRideSession {
        GroupRideSession(
            backend: SupabaseGroupRideBackend(),
            transport: SupabaseRideSessionTransport(),
            displayNameProvider: {
                UserDefaults.standard.string(forKey: DisplayNameStore.crewDisplayNameKey) ?? ""
            }
        )
    }
}
