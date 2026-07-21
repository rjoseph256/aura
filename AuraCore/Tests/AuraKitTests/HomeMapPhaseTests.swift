import Testing
@testable import AuraKit

@Suite struct HomeMapPhaseTests {
    @Test func tapActivatesLiveFromIdle() { #expect(HomeMapReducer.next(.idle, on: .activate) == .live) }
    @Test func leavingTopOrBackgroundReturnsToIdle() {
        #expect(HomeMapReducer.next(.live, on: .resignedTop) == .idle)
        #expect(HomeMapReducer.next(.live, on: .background) == .idle)
    }
    @Test func returningToHomeDoesNotAutoActivate() {
        #expect(HomeMapReducer.next(.idle, on: .becameTopActive) == .idle)
        #expect(HomeMapReducer.next(.live, on: .becameTopActive) == .live)
    }
    @Test func idleIgnoresLeaveTriggers() { #expect(HomeMapReducer.next(.idle, on: .resignedTop) == .idle) }
}
