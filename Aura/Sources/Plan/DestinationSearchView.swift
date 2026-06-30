import SwiftUI
import MapboxSearch
import MapboxMaps
import CoreLocation
import AuraCore

// MARK: - DestinationSearchView

/// A live-search field backed by Mapbox PlaceAutocomplete.
/// Debounces keystrokes (~300 ms), fetches suggestions for queries ≥ 2 chars,
/// then resolves the coordinate on selection via `placeAutocomplete.select(suggestion:)`.
struct DestinationSearchView: View {
    @Binding var query: String
    let onPick: (Place) -> Void

    @State private var suggestions: [PlaceAutocomplete.Suggestion] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var debounceTask: Task<Void, Never>?

    // The Search SDK does NOT read MapboxOptions.accessToken; it requires an explicit
    // token (or Info.plist MBXAccessToken). We pass the token configured at launch.
    private let placeAutocomplete = PlaceAutocomplete(accessToken: MapboxOptions.accessToken)

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: AuraTheme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AuraTheme.textSecondary)
                    .font(.body.weight(.medium))

                TextField("", text: $query, prompt:
                    Text("Where to?")
                        .foregroundColor(AuraTheme.textPrimary.opacity(0.65))
                )
                .foregroundStyle(AuraTheme.textPrimary)
                .font(.body)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)

                if !query.isEmpty {
                    Button {
                        query = ""
                        suggestions = []
                        errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AuraTheme.textSecondary)
                            .font(.callout)
                    }
                    .accessibilityLabel("Clear search")
                }

                if isLoading {
                    ProgressView()
                        .tint(AuraTheme.accent)
                        .scaleEffect(0.85)
                }
            }
            .frame(minHeight: 56)
            .padding(.horizontal, AuraTheme.Spacing.lg)
            .background(AuraTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: AuraTheme.Radius.lg, style: .continuous))
            .padding(.horizontal, AuraTheme.Spacing.xxl)

            // Results list (only visible when typing)
            if !query.isEmpty {
                if let error = errorMessage {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(AuraTheme.textSecondary)
                        .padding(.vertical, AuraTheme.Spacing.xl)
                        .padding(.horizontal, AuraTheme.Spacing.xxl)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(suggestions, id: \.rowKey) { suggestion in
                            SuggestionRow(suggestion: suggestion) {
                                resolveSuggestion(suggestion)
                            }
                            if suggestion.rowKey != suggestions.last?.rowKey {
                                Divider()
                                    .background(AuraTheme.border)
                                    .padding(.leading, 60)
                            }
                        }
                    }
                    .background(AuraTheme.surface.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: AuraTheme.Radius.md, style: .continuous))
                    .padding(.horizontal, AuraTheme.Spacing.xxl)
                    .padding(.top, AuraTheme.Spacing.sm)
                }
            }
        }
        .onChange(of: query) { _, newValue in
            scheduleSearch(for: newValue)
        }
    }

    // MARK: - Search

    private func scheduleSearch(for text: String) {
        debounceTask?.cancel()
        suggestions = []
        errorMessage = nil

        guard text.count >= 2 else {
            isLoading = false
            return
        }

        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300 ms debounce
            guard !Task.isCancelled else { return }
            await fetchSuggestions(for: text)
        }
    }

    @MainActor
    private func fetchSuggestions(for text: String) async {
        isLoading = true
        defer { isLoading = false }

        await withCheckedContinuation { continuation in
            placeAutocomplete.suggestions(for: text) { result in
                switch result {
                case .success(let items):
                    suggestions = items
                    errorMessage = nil
                case .failure(let error):
                    suggestions = []
                    errorMessage = "Search failed: \(error.localizedDescription)"
                }
                continuation.resume()
            }
        }
    }

    // MARK: - Selection & resolution

    private func resolveSuggestion(_ suggestion: PlaceAutocomplete.Suggestion) {
        // If the suggestion already carries a coordinate, use it immediately
        if let coord = suggestion.coordinate, CLLocationCoordinate2DIsValid(coord) {
            let place = Place(
                name: suggestion.name,
                coordinate: Coordinate(latitude: coord.latitude, longitude: coord.longitude),
                category: inferCategory(from: suggestion)
            )
            onPick(place)
            query = ""
            suggestions = []
            return
        }

        // Otherwise call select to resolve the full result (network round-trip)
        isLoading = true
        placeAutocomplete.select(suggestion: suggestion) { result in
            DispatchQueue.main.async {
                isLoading = false
                switch result {
                case .success(let resolved):
                    guard let coord = resolved.coordinate,
                          CLLocationCoordinate2DIsValid(coord) else {
                        errorMessage = "Could not resolve location."
                        return
                    }
                    let place = Place(
                        name: resolved.name,
                        coordinate: Coordinate(latitude: coord.latitude, longitude: coord.longitude),
                        category: inferCategory(from: suggestion, resolved: resolved)
                    )
                    onPick(place)
                    query = ""
                    suggestions = []
                case .failure(let error):
                    errorMessage = "Could not load location: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Category inference

    private func inferCategory(
        from suggestion: PlaceAutocomplete.Suggestion,
        resolved: PlaceAutocomplete.Result? = nil
    ) -> Place.Category {
        let cats = resolved?.categories ?? suggestion.categories
        let ids  = resolved?.categoryIds ?? suggestion.categoryIds
        let all  = (cats + ids).map { $0.lowercased() }

        for token in all {
            if token.contains("brewery") || token.contains("bar") || token.contains("beer") {
                return .brewery
            }
            if token.contains("park") || token.contains("trail") || token.contains("hiking") ||
               token.contains("nature") || token.contains("recreation") {
                return .trailhead
            }
        }

        // Fall back on result type
        switch suggestion.placeType {
        case .address: return .address
        default:       return .custom
        }
    }
}

// MARK: - SuggestionRow

private struct SuggestionRow: View {
    let suggestion: PlaceAutocomplete.Suggestion
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: AuraTheme.Spacing.lg) {
                Image(systemName: rowIcon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AuraTheme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(AuraTheme.textPrimary)
                        .lineLimit(1)
                    if let desc = suggestion.description, !desc.isEmpty {
                        Text(desc)
                            .font(.footnote)
                            .foregroundStyle(AuraTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .frame(minHeight: 56)
            .padding(.horizontal, AuraTheme.Spacing.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rowIcon: String {
        let cats = (suggestion.categories + suggestion.categoryIds).map { $0.lowercased() }
        for token in cats {
            if token.contains("brewery") || token.contains("bar") || token.contains("beer") {
                return "mug.fill"
            }
            if token.contains("park") || token.contains("trail") || token.contains("hiking") {
                return "figure.hiking"
            }
        }
        switch suggestion.placeType {
        case .address: return "mappin.circle.fill"
        default:       return "mappin"
        }
    }
}

private extension PlaceAutocomplete.Suggestion {
    /// Stable content key for SwiftUI list identity. The type exposes no id, and the
    /// previous array-offset key churned row identity as results streamed in. Name +
    /// description + coordinate is stable across a re-fetch of the same place.
    var rowKey: String {
        let lat = coordinate?.latitude ?? 0
        let lon = coordinate?.longitude ?? 0
        return "\(name)|\(description ?? "")|\(lat),\(lon)"
    }
}
