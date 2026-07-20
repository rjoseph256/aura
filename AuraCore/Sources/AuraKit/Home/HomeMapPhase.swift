public enum HomeMapPhase: Sendable, Equatable { case idle, live }
public enum HomeMapTrigger: Sendable, Equatable {
    case activate, resignedTop, background, becameTopActive
}
public enum HomeMapReducer {
    public static func next(_ phase: HomeMapPhase, on trigger: HomeMapTrigger) -> HomeMapPhase {
        switch trigger {
        case .activate: return .live
        case .resignedTop, .background: return .idle
        case .becameTopActive: return phase // returning to Home never auto-activates
        }
    }
}
