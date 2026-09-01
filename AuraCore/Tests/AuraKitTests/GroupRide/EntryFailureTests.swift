import Testing
import Foundation
@testable import AuraKit

struct EntryFailureTests {
    struct SomeError: Error {}

    @Test func timeoutReadsAsConnectionFailure() {
        #expect(EntryFailure.isConnectionFailure(TimeoutError()))
    }
    @Test func typedConnectionFailureReadsAsConnectionFailure() {
        #expect(EntryFailure.isConnectionFailure(GroupRideError.connectionFailed))
    }
    @Test func urlErrorReadsAsConnectionFailure() {
        #expect(EntryFailure.isConnectionFailure(URLError(.notConnectedToInternet)))
    }
    @Test func aWrappedURLErrorIsUnwrappedOneLevel() {
        let wrapped = NSError(domain: "auth", code: 1,
                              userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)])
        #expect(EntryFailure.isConnectionFailure(wrapped))
    }
    @Test func aServerRejectionIsNotAConnectionFailure() {
        #expect(!EntryFailure.isConnectionFailure(GroupRideError.joinFailed))
    }
    @Test func cancellationIsNotAConnectionFailure() {
        // withTimeout owns the CancellationError → TimeoutError conversion; the classifier
        // must not pre-empt it (and Task 5's backend rethrows cancellation for the same reason).
        #expect(!EntryFailure.isConnectionFailure(CancellationError()))
    }
    @Test func anUnknownErrorDefaultsToRejected() {
        #expect(!EntryFailure.isConnectionFailure(SomeError()))
    }
}
