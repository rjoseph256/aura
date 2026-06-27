// AuraCore/Sources/AuraKit/Widgets/WidgetSnapshotStore.swift
import Foundation

/// The shared App Group identifier. The app writes the widget snapshot into this group's
/// container and the widget reads it; one constant stops the two sides from drifting.
public enum AppGroup {
    public static let identifier = "group.app.aura.ios"
}

/// Reads and writes the `WidgetSnapshot` as a JSON file. The directory is injected so the
/// store is testable on the macOS CI host with a temp directory; production resolves the
/// App Group container (nil, and a graceful no-op, when the entitlement is absent — e.g. an
/// unsigned build or the CI host).
public struct WidgetSnapshotStore {
    private let directory: URL?
    private let fileName = "widget-snapshot.json"

    /// Inject a directory in tests; production uses `appGroup()`.
    public init(directory: URL?) { self.directory = directory }

    /// The shared App-Group-backed store the app writes and the widget reads.
    public static func appGroup() -> WidgetSnapshotStore {
        WidgetSnapshotStore(directory: FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier))
    }

    public func write(_ snapshot: WidgetSnapshot) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Returns nil when the container is unavailable, the file is missing, the JSON fails to
    /// decode, or the version is unrecognized. Every failure folds to "no snapshot", which
    /// the widget views render as their empty state.
    public func read() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              snapshot.version == WidgetSnapshot.currentVersion else { return nil }
        return snapshot
    }

    private var fileURL: URL? { directory?.appendingPathComponent(fileName) }
}
