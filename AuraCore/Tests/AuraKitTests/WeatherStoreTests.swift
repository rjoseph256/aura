import Testing
import Foundation
@testable import AuraKit
import AuraCore

private func snap(_ tempC: Double, _ at: Date, _ coord: Coordinate) -> WeatherSnapshot {
    WeatherSnapshot(temperature: Measurement(value: tempC, unit: .celsius),
                    condition: .clear, asOf: at, coordinate: coord)
}
private let pgh = Coordinate(latitude: 40.44, longitude: -79.99)

@MainActor @Test func firstRefreshSetsSnapshot() async {
    let t0 = Date(timeIntervalSince1970: 0)
    let store = WeatherStore(provider: StubWeatherProvider(.success(snap(20, t0, pgh))))
    await store.refresh(near: pgh, now: t0)
    #expect(store.snapshot?.temperature.value == 20)
}

@MainActor @Test func providerThrowLeavesSnapshotNil() async {
    let store = WeatherStore(provider: StubWeatherProvider(.failure(StubError())))
    await store.refresh(near: pgh, now: Date(timeIntervalSince1970: 0))
    #expect(store.snapshot == nil)
}

@MainActor @Test func providerThrowLeavesExistingSnapshotUnchanged() async {
    let t0 = Date(timeIntervalSince1970: 0)
    let stub = StubWeatherProvider(.success(snap(20, t0, pgh)))
    let store = WeatherStore(provider: stub)
    await store.refresh(near: pgh, now: t0)
    stub.result = .failure(StubError())
    await store.refresh(near: pgh, now: t0.addingTimeInterval(1_000)) // cache-miss, then throws
    #expect(store.snapshot?.temperature.value == 20)                  // unchanged
}

@MainActor @Test func cacheHitSkipsSecondFetch() async {
    let t0 = Date(timeIntervalSince1970: 0)
    let stub = StubWeatherProvider(.success(snap(20, t0, pgh)))
    let store = WeatherStore(provider: stub)
    await store.refresh(near: pgh, now: t0)
    await store.refresh(near: pgh, now: t0.addingTimeInterval(600)) // 10 min, same spot
    #expect(stub.callCount == 1)
}

@MainActor @Test func cacheMissOnStalenessOrMovementRefetches() async {
    let t0 = Date(timeIntervalSince1970: 0)
    let stub = StubWeatherProvider(.success(snap(20, t0, pgh)))
    let store = WeatherStore(provider: stub)
    await store.refresh(near: pgh, now: t0)
    await store.refresh(near: pgh, now: t0.addingTimeInterval(1_000)) // > 15 min
    #expect(stub.callCount == 2)
    let far = Coordinate(latitude: 41.0, longitude: -79.99)           // ~62 km away
    await store.refresh(near: far, now: t0.addingTimeInterval(1_100))
    #expect(stub.callCount == 3)
}

@MainActor @Test func displaySnapshotHidesPastStaleness() async {
    let t0 = Date(timeIntervalSince1970: 0)
    let store = WeatherStore(provider: StubWeatherProvider(.success(snap(20, t0, pgh))))
    await store.refresh(near: pgh, now: t0)
    #expect(store.displaySnapshot(now: t0.addingTimeInterval(1_800)) != nil) // 30 min
    #expect(store.displaySnapshot(now: t0.addingTimeInterval(3_600)) == nil) // 60 min
}
