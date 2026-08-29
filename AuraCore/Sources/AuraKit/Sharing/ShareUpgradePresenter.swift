import Foundation
import Observation

/// Opened once; waiters arriving after it is open return immediately.
@MainActor
private final class DwellGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() {
        guard !isOpen else { return }
        isOpen = true
        let resuming = waiters
        waiters = []
        for waiter in resuming { waiter.resume() }
    }
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@Observable @MainActor
public final class ShareUpgradePresenter {
    public private(set) var phase: ShareUpgradePhase = .idle

    @ObservationIgnored private let showDelayDuration: Duration
    @ObservationIgnored private let deadlineDuration: Duration
    @ObservationIgnored private let dwellDuration: Duration
    @ObservationIgnored private let showDelayTimer: @Sendable (Duration) async -> Void
    @ObservationIgnored private let deadlineTimer: @Sendable (Duration) async -> Void
    @ObservationIgnored private let dwellTimer: @Sendable (Duration) async -> Void

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var attemptsInFlight = 0
    @ObservationIgnored private var indicatorShown = false
    @ObservationIgnored private var dwellGate: DwellGate?
    @ObservationIgnored private var hops: [Task<Void, Never>] = []
    /// Held apart from `hops` on purpose — see `enterIndicator` (ROH-186).
    @ObservationIgnored private var dwellHop: Task<Void, Never>?

    public init(showDelay: Duration = .milliseconds(300),
                deadline: Duration = .seconds(6),
                minimumDwell: Duration = .seconds(1),
                showDelayTimer: (@Sendable (Duration) async -> Void)? = nil,
                deadlineTimer: (@Sendable (Duration) async -> Void)? = nil,
                dwellTimer: (@Sendable (Duration) async -> Void)? = nil) {
        self.showDelayDuration = showDelay
        self.deadlineDuration = deadline
        self.dwellDuration = minimumDwell
        self.showDelayTimer = showDelayTimer ?? { try? await Task.sleep(for: $0) }
        self.deadlineTimer = deadlineTimer ?? { try? await Task.sleep(for: $0) }
        self.dwellTimer = dwellTimer ?? { try? await Task.sleep(for: $0) }
    }

    public func noUpgradePossible() {
        cancelHops()
        generation += 1
        phase = .idle
    }

    public func attempt(origin: AttemptOrigin, _ work: () async -> ShareUpgradeResult) async {
        generation += 1
        let mine = generation
        attemptsInFlight += 1
        cancelHops()

        if origin == .first {
            indicatorShown = false
            phase = .upgrading
            arm { [weak self] in
                guard let self else { return }
                await self.showDelayTimer(self.showDelayDuration)
                guard !Task.isCancelled, mine == self.generation, self.phase == .upgrading else { return }
                self.enterIndicator()
            }
        } else {
            enterIndicator()
        }

        arm { [weak self] in
            guard let self else { return }
            await self.deadlineTimer(self.deadlineDuration)
            guard !Task.isCancelled, mine == self.generation,
                  self.phase == .upgrading || self.phase == .upgradingVisible else { return }
            self.phase = .unavailable(.mayRejoin)
        }

        let result = await work()
        attemptsInFlight -= 1

        // Only the newest attempt's terminal outcome may set the phase. An older attempt's
        // MAP is still applied — a map is a map.
        guard mine == generation || result == .gotMap else { return }
        if mine == generation { cancelHops() }

        if indicatorShown, let gate = dwellGate { await gate.wait() }
        guard mine == generation || result == .gotMap else { return }
        // `.upgraded` absorbs. A newer attempt's reject must never retract a map the rider
        // already has — reachable whenever an older attempt's map lands while a newer one is
        // still outstanding, which is exactly what the "a map is a map" rule creates.
        if case .upgraded = phase { return }

        phase = terminal(for: result)
    }

    private func enterIndicator() {
        indicatorShown = true
        phase = .upgradingVisible
        let gate = DwellGate()
        dwellGate = gate
        // ROH-186. This hop is deliberately NOT armed through `arm`, because `cancelHops()` runs
        // one line before `attempt` awaits this gate. The production timer is a cancellable
        // `Task.sleep` whose cancellation `try?` swallows, so a cancelled dwell hop falls
        // straight through to `gate.open()` and the floor evaporates — measured at 10.8 ms
        // against a specified 1000 ms. Every ManualTimer-based test missed it because the fake
        // ignores cancellation; `testTheDwellSurvivesTerminalPathHopCancellation` uses a
        // cancellation-honouring timer for exactly that reason.
        //
        // Cancelling the PREVIOUS hop is safe and bounds the live count at one: `attempt` reads
        // `dwellGate` at the moment it waits, so it always waits on the newest gate, which the
        // newest hop opens. Guarding on `Task.isCancelled` instead would wedge — the gate would
        // never open, `attempt` would never return, and the phase would stick on an absorbing
        // `.upgradingVisible`.
        dwellHop?.cancel()
        dwellHop = Task { [dwellTimer, dwellDuration] in
            await dwellTimer(dwellDuration)
            gate.open()
        }
    }

    private func terminal(for result: ShareUpgradeResult) -> ShareUpgradePhase {
        switch result {
        // `origin` is no longer consulted: with the automatic retry gone every attempt has a
        // rider behind it, so an indicator that was on screen is the whole question.
        case .gotMap:        return .upgraded(confirming: indicatorShown)
        case .rejected:      return .unavailable(.freshAttempt)
        case .stoppedWaiting: return .unavailable(.mayRejoin)
        }
    }

    private func arm(_ body: @escaping @MainActor () async -> Void) {
        hops.append(Task { await body() })
    }

    private func cancelHops() {
        for hop in hops { hop.cancel() }
        hops = []
    }
}
