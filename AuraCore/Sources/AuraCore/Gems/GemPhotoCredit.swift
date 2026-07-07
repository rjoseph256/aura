import Foundation

/// The credit line shown under a gem photo, or nil when none is needed.
/// `build_gems.py` collapses public-domain/CC0 to a nil attribution, so any
/// non-empty attribution here is a license that requires visible credit.
public func gemPhotoCredit(_ attribution: String?) -> String? {
    guard let attribution else { return nil }
    let trimmed = attribution.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : "Photo: \(trimmed)"
}
