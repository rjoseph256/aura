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

    @ObservationIgnored public var onAutomaticRetry: (@MainActor () -> Void)?

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
    @ObservationIgnored private var armedAutomaticRetry = false
    @ObservationIgnored private var hasAutomaticallyRetried = false

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

    public var isAttempting: Bool { attemptsInFlight > 0 }

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

        phase = terminal(for: result, origin: origin)
        consumeAutomaticRetryIfDue()
    }

    /// A real background→foreground return happened. Arms one automatic retry, consumed when the
    /// phase next becomes `.unavailable(.freshAttempt)` — or now, if it already is and nothing is
    /// in flight. Never evaluated at the scene edge: on resume the parked belts are many
    /// main-actor hops behind, so reading the phase there would always be too early.
    public func armAutomaticRetry() {
        guard !hasAutomaticallyRetried else { return }
        armedAutomaticRetry = true
        consumeAutomaticRetryIfDue()
    }

    private func consumeAutomaticRetryIfDue() {
        guard armedAutomaticRetry, !hasAutomaticallyRetried, attemptsInFlight == 0,
              phase == .unavailable(.freshAttempt) else { return }
        armedAutomaticRetry = false
        hasAutomaticallyRetried = true
        let callback = onAutomaticRetry
        // NEVER invoked synchronously from inside `attempt`: the callback re-enters this type,
        // and a hop keeps that re-entry out of the current attempt's unwind.
        Task { @MainActor in callback?() }
    }

    private func enterIndicator() {
        indicatorShown = true
        phase = .upgradingVisible
        let gate = DwellGate()
        dwellGate = gate
        arm { [weak self] in
            guard let self else { return }
            await self.dwellTimer(self.dwellDuration)
            gate.open()
        }
    }

    private func terminal(for result: ShareUpgradeResult, origin: AttemptOrigin) -> ShareUpgradePhase {
        switch result {
        case .gotMap:        return .upgraded(confirming: origin != .automatic && indicatorShown)
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
