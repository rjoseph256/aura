import Foundation

/// Which way a create/join attempt failed. Carried by `GroupRideSession` ALONGSIDE its
/// payload-free `Phase` — an associated value would break `phase ==` and the ROH-81
/// single-branch `if`. Client-detectable causes only; the server's join answer stays a
/// deliberately generic oracle (ROH-226), so `.rejected` never guesses at a cause.
public enum EntryFailureReason: Equatable, Sendable {
    case connectionFailed
    case rejected
}

public enum EntryFailure {
    /// True when the error means the server was never reached (or never answered in time),
    /// as opposed to answering and saying no. `CancellationError` is deliberately NOT a
    /// connection failure — `withTimeout` owns that conversion (a genuine timeout surfaces
    /// here as `TimeoutError`). Walks one level of underlying error because SDK auth
    /// wrappers can carry the transport error inside.
    public static func isConnectionFailure(_ error: any Error) -> Bool {
        if error is TimeoutError { return true }
        if (error as? GroupRideError) == .connectionFailed { return true }
        if error is URLError { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain || ns.domain == NSPOSIXErrorDomain { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSURLErrorDomain || underlying.domain == NSPOSIXErrorDomain
        }
        return false
    }
}
