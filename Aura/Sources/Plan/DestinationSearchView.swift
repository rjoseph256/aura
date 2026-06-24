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
    @State private var errorMessage: String? = nil
    @State private var debounceTask: Task<Void, Never>? = nil

    // The Search SDK does NOT read MapboxOptions.accessToken; it requires an explicit
    // token (or Info.plist MBXAccessToken). We pass the token configured at launch.
    private let placeAutocomplete = PlaceAutocomplete(accessToken: MapboxOptions.accessToken)

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(AuraTheme.muted)
                    .font(.system(size: 17, weight: .medium))

                TextField("", text: $query, prompt:
                    Text("Where to?")
                        .foregroundColor(AuraTheme.text.opacity(0.65))
                )
                .foregroundColor(AuraTheme.text)
                .font(.system(size: 17, weight: .regular))
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
                            .foregroundColor(AuraTheme.muted)
                            .font(.system(size: 16))
                    }
                }

                if isLoading {
                    ProgressView()
                        .tint(AuraTheme.cyan)
                        .scaleEffect(0.85)
                }
            }
            .frame(minHeight: 56)
            .padding(.horizontal, 16)
            .background(AuraTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 24)

            // Results list (only visible when typing)
            if !query.isEmpty {
                if let error = errorMessage {
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(AuraTheme.muted)
                        .padding(.vertical, 20)
                        .padding(.horizontal, 24)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
                            SuggestionRow(suggestion: suggestion) {
                                resolveSuggestion(suggestion)
                            }
                            if suggestion.name != suggestions.last?.name {
                                Divider()
                                    .background(AuraTheme.surface)
                                    .padding(.leading, 60)
                            }
                        }
                    }
                    .background(AuraTheme.surface.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
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
            HStack(spacing: 14) {
                Image(systemName: rowIcon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AuraTheme.cyan)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(AuraTheme.text)
                        .lineLimit(1)
                    if let desc = suggestion.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 13))
                            .foregroundColor(AuraTheme.muted)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .frame(minHeight: 56)
            .padding(.horizontal, 16)
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