import SwiftUI
import AuraCore
import AuraKit

/// Owns the group-ride session for one navigation-stack entry: constructs the live
/// `GroupRideSession` around the app's real Supabase backend/transport, drives the
/// create-or-join call the entry asks for, and switches on `session.phase` to present
/// the right screen. `.riding` forks on the ride's stored `kind` (ROH-114 D4.1): a route ride
/// renders `GroupNavigateContainer`, which composes the crew chrome (roster/toasts/pill) over
/// the solo `NavigateHUDView`; a destination-free ride renders the Explore cockpit
/// (`RideHUDView`), which has no route to follow and so nothing for the navigation cockpit to
/// show (D8).
struct GroupRideFlowView: View {
    let entry: GroupRideEntry

    @Environment(AppRouter.self) private var router
    @Environment(SettingsStore.self) private var settings
    @Environment(\.scenePhase) private var scenePhase

    /// The destination's name, carried on the entry so the lobby can name it (D5.4). A guest's
    /// entry is `.join`, which has no place — the copy handles that.
    private var entryPlaceName: String? {
        if case let .create(_, place) = entry { return place?.name }
        return nil
    }

    @State private var session: GroupRideSession
    @State private var displayNameStore = DisplayNameStore(backend: Self.liveBackend())
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
            #if DEBUG
            .onChange(of: session.phase) { _, phase in
                if phase == .lobby, let code = session.joinCode {
                    GroupRideDemoMode.startDemoCrewIfRequested(code: code)
                }
            }
            #endif
    }

    /// A rider who actually entered `.riding` and whose ride later ends (host-end, D9) must
    /// NOT have the HUD torn down — the in-progress solo navigation (owned by the
    /// `RideSessionCoordinator` inside `GroupNavigateContainer`'s `NavigateHUDView`) would be
    /// abandoned, its recording discarded, and the end-summary lost (it would be set on a
    /// destroyed coordinator). So `.riding` and the "rode, then ended" case of `.ended` share
    /// ONE structural branch here — a single `if`, not two `switch` cases. SwiftUI gives each
    /// `switch` case its own `_ConditionalContent` identity, so routing both phases through
    /// separate cases (even to the same `ridingContainer`) rebuilds the subtree on the
    /// `.riding → .ended` transition and destroys that `@State` (ROH-81 device finding). A ride
    /// that ends while the rider is still in the lobby/join flow never had a HUD to preserve, so
    /// it falls to `otherPhaseContent`'s dedicated ended surface.
    @ViewBuilder private var content: some View {
        if session.phase == .riding || (session.phase == .ended && didEnterRiding) {
            ridingContainer
        } else {
            otherPhaseContent
        }
    }

    @ViewBuilder private var otherPhaseContent: some View {
        switch session.phase {
        case .idle:
            entryLoading

        case .needsDisplayName:
            // No wrapping NavigationStack here: this whole view is already a pushed
            // destination inside the app's root NavigationStack, and nesting a second
            // NavigationStack inside a pushed column makes SwiftUI's path reconciliation
            // (NavigationColumnState.boundPathChange) throw swift_unexpectedError and
            // crash the app. DisplayNameEditor only needs *a* navigation context for its
            // `.navigationTitle`, which the root stack already provides.
            DisplayNameEditor(store: displayNameStore,
                              contextLine: "Pick a crew name — it's how your crew sees you.") {
                Task { await invokeEntry() }
            }

        case .lobby:
            // The place name comes off the entry, not the session: it is presentation, and the
            // session deliberately knows only about the route (D5.4).
            GroupLobbyView(session: session,
                           placeName: entryPlaceName,
                           isImperial: settings.units == .imperial)

        // Reached only when `!didEnterRiding` (the `content` `if` owns the rode-then-ended
        // case): the ride ended while the rider was still in the lobby/join flow, so there's no
        // HUD to preserve — show a terminal surface.
        case .ended:
            endedLobbySurface

        case .createFailed:
            dismissMessage(
                title: connectionFailed ? "Couldn't reach the ride." : "Couldn't start your crew ride.",
                detail: connectionFailed ? "Check your connection and try again." : "Try again in a moment.",
                systemImage: connectionFailed ? "wifi.exclamationmark" : "person.2.slash",
                retryTitle: "Try again",
                retry: { Task { await invokeEntry() } }
            )

        case .routeUnavailable:
            dismissMessage(
                title: "Couldn't load this ride's route.",
                detail: "Ask your host to check the ride, then try joining again.",
                systemImage: "exclamationmark.triangle"
            )

        case .joinFailed:
            dismissMessage(
                title: connectionFailed ? "Couldn't reach the ride." : "Couldn't join that ride.",
                detail: connectionFailed ? "Check your connection and try again."
                                         : "Check the code with your host and try again.",
                systemImage: connectionFailed ? "wifi.exclamationmark" : "person.crop.circle.badge.xmark",
                retryTitle: "Try again",
                retry: {
                    // .joinFailed is only written by join(code:), so the entry is always .join
                    // (gate: v1's else-branch here was dead code).
                    if case let .join(code) = entry {
                        router.replaceTop(with: .joinRide(seed: code.rawValue))
                    }
                }
            )

        // Unreachable: `content`'s `if` renders `.riding`. Here only for switch exhaustiveness.
        case .riding:
            EmptyView()
        }
    }

    // MARK: - Entry-aware loading

    /// Entry-aware, bounded loading (ROH-231): the session's entryTimeout guarantees this
    /// resolves — a hung create/join lands on the connection-failure surface, never here forever.
    private var entryLoading: some View {
        VStack(spacing: AuraTheme.Spacing.lg) {
            Image(systemName: "person.2.fill")
                .font(.largeTitle)
                .foregroundStyle(AuraTheme.textSecondary)
            ProgressView()
            Text(entryIsJoin ? "Joining your crew…" : "Setting up your crew ride…")
                .font(.subheadline)
                .foregroundStyle(AuraTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AuraTheme.background.ignoresSafeArea())
    }

    private var entryIsJoin: Bool {
        if case .join = entry { return true }
        return false
    }

    /// Distinguishes a client-detectable transport failure (server never reached) from a
    /// server rejection, so the failure surfaces can give honest, distinct copy (ROH-231).
    private var connectionFailed: Bool { session.entryFailureReason == .connectionFailed }

    // MARK: - Riding / ended-while-riding

    /// `.riding`, plus the "rode, then the ride ended" case of `.ended` (`didEnterRiding`
    /// true) — see the phase switch above for why those two share a screen. `.task`'s
    /// first-run flips `didEnterRiding` before awaiting `beginLiveSession()`, so a
    /// same-tick ended transition (a ride that ended the instant it was joined) still
    /// counts as "entered riding" once this container has mounted. `.task` is keyed to
    /// this view's identity, not to phase, so the ended transition doesn't restart it.
    @ViewBuilder private var ridingContainer: some View {
        if session.rideKind == .open {
            // A destination-free crew ride rides the Explore cockpit (D4.1/D8): there is no
            // route to follow, so the navigation cockpit has nothing to show.
            RideHUDView(groupSession: session)
                .task {
                    didEnterRiding = true
                    await session.beginLiveSession()
                }
        } else if session.route != nil {
            GroupNavigateContainer(session: session)
                .task {
                    didEnterRiding = true
                    await session.beginLiveSession()
                }
        } else {
            // Now genuinely a corrupt payload: a ride whose stored kind says it HAS a route,
            // whose route did not survive to this screen. Before ROH-114 this branch also
            // caught destination-free rides and told their riders their route had failed to
            // load — a dead end whose only control popped the flow view without leaving the
            // ride, stranding the crew on a ride nobody could end.
            dismissMessage(
                title: "Couldn't load this ride's route.",
                detail: "Ask your host to check the ride, then try joining again.",
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
        // The place is not passed to the session: it is presentation, read straight off the
        // entry by the lobby (D5.4). The session's business is the route, which is nil for an
        // open ride.
        case let .create(route, _):
            await session.create(route: route)
        case let .join(code):
            await session.join(code: code)
        }
    }

    // MARK: - Dismiss-with-message

    private func dismissMessage(title: String, detail: String? = nil, systemImage: String,
                                retryTitle: String? = nil, retry: (() -> Void)? = nil) -> some View {
        VStack(spacing: AuraTheme.Spacing.lg) {
            Spacer()
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(AuraTheme.textSecondary)
            VStack(spacing: AuraTheme.Spacing.xs) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AuraTheme.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(AuraTheme.textSecondary)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, AuraTheme.Spacing.xxl)
            Spacer()
            VStack(spacing: AuraTheme.Spacing.sm) {
                if let retryTitle, let retry {
                    Button(retryTitle, action: retry).buttonStyle(.ctaPrimary)
                    Button("Back") { router.pop() }.buttonStyle(.ctaTertiary)
                } else {
                    Button("Back") { router.pop() }.buttonStyle(.ctaPrimary)
                }
            }
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
            backend: Self.liveBackend(),
            transport: Self.liveTransport(),
            displayNameProvider: {
                UserDefaults.standard.string(forKey: DisplayNameStore.crewDisplayNameKey) ?? ""
            }
        )
    }

    /// Real backend, except under the DEBUG demo launch argument (ROH-225), which routes
    /// every group surface to the shared in-memory fake so Claude can drive them on a
    /// simulator with no Apple Account. Release builds compile only the `return` line.
    @MainActor
    private static func liveBackend() -> any GroupRideBackend {
        #if DEBUG
        if GroupRideDemoMode.isActive { return GroupRideDemoMode.backend }
        #endif
        return SupabaseGroupRideBackend()
    }

    /// Real transport, except under the DEBUG demo launch argument — see `liveBackend()`.
    @MainActor
    private static func liveTransport() -> any RideSessionTransport {
        #if DEBUG
        if GroupRideDemoMode.isActive { return InMemoryRideSessionTransport() }
        #endif
        return SupabaseRideSessionTransport()
    }
}
