import SwiftUI
import AuraCore
import AuraKit

/// Owns the group-ride session for one navigation-stack entry: constructs the live
/// `GroupRideSession` around the app's real Supabase backend/transport, drives the
/// create-or-join call the entry asks for, and switches on `session.phase` to present
/// the right screen. `Task 17` swaps the `.riding` placeholder for the full
/// `GroupNavigateContainer`; everything else here is final.
struct GroupRideFlowView: View {
    let entry: GroupRideEntry

    @Environment(AppRouter.self) private var router

    @State private var session: GroupRideSession
    @State private var displayNameStore = DisplayNameStore()

    init(entry: GroupRideEntry) {
        self.entry = entry
        _session = State(initialValue: GroupRideFlowView.makeSession())
    }

    var body: some View {
        content
            .task { await invokeEntry() }
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .idle:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AuraTheme.background.ignoresSafeArea())

        case .needsDisplayName:
            NavigationStack {
                DisplayNameEditor(store: displayNameStore) {
                    Task { await invokeEntry() }
                }
            }

        case .lobby:
            GroupLobbyView(session: session)

        case .riding:
            if let route = session.route {
                NavigateHUDView(route: route, destination: nil)
                    .task { await session.beginLiveSession() }
            } else {
                // Guarded per the brief: `.riding` with no route is unreachable in
                // practice (create/join both set `route` before this phase), but
                // render something sane rather than a blank screen.
                dismissMessage(
                    title: "Couldn't load this ride's route.",
                    systemImage: "exclamationmark.triangle"
                )
            }

        case .createFailed:
            dismissMessage(
                title: "This route is too detailed to share as a group ride.",
                systemImage: "point.topleft.down.curvedto.point.bottomright.up"
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

        case .ended:
            Color.clear
                .onAppear { router.pop() }
        }
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
    /// crew display name from the same `crewDisplayName` UserDefaults key
    /// `DisplayNameStore` owns.
    @MainActor
    private static func makeSession() -> GroupRideSession {
        GroupRideSession(
            backend: SupabaseGroupRideBackend(),
            transport: SupabaseRideSessionTransport(),
            displayNameProvider: { UserDefaults.standard.string(forKey: "crewDisplayName") ?? "" }
        )
    }
}
