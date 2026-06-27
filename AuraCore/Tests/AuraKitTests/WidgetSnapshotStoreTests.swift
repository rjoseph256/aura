// AuraCore/Tests/AuraKitTests/WidgetSnapshotStoreTests.swift
import Testing
import Foundation
@testable import AuraKit

@Suite struct WidgetSnapshotStoreTests {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func writeThenRead_returnsEqualSnapshot() {
        let store = WidgetSnapshotStore(directory: tempDir())
        store.write(.sample)
        #expect(store.read() == .sample)
    }

    @Test func read_missingFile_returnsNil() {
        #expect(WidgetSnapshotStore(directory: tempDir()).read() == nil)
    }

    @Test func read_corruptFile_returnsNil() throws {
        let dir = tempDir()
        try Data("not json".utf8).write(to: dir.appendingPathComponent("widget-snapshot.json"))
        #expect(WidgetSnapshotStore(directory: dir).read() == nil)
    }

    @Test func read_versionMismatch_returnsNil() throws {
        let dir = tempDir()
        let json = """
        {"version":999,"generatedAt":0,"units":"imperial","lastRide":null,\
        "week":{"distanceMeters":0,"rideCount":0,"goalMeters":40000,"start":0,"end":0}}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("widget-snapshot.json"))
        #expect(WidgetSnapshotStore(directory: dir).read() == nil)
    }

    @Test func nilDirectory_writeNoOps_readNil() {
        let store = WidgetSnapshotStore(directory: nil)
        store.write(.sample) // must not crash
        #expect(store.read() == nil)
    }
}
