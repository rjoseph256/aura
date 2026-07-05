import SwiftUI
import AuraCore

/// The expanded view for a gem, opened by tapping its pin or peek card. Info only in Plan 2;
/// the "Take me there" CTA + the guided detour land in Plan 3.
struct GemDetailSheet: View {
    let gem: Gem
    let distanceText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: GemPinView.symbol(for: gem.category))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AuraTheme.onAccent)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(AuraTheme.accent))
                VStack(alignment: .leading, spacing: 2) {
                    Text(gem.name).font(.title3.weight(.semibold)).foregroundStyle(AuraTheme.textPrimary)
                    Text("\(gem.category.rawValue.capitalized) · \(distanceText)")
                        .font(.subheadline).foregroundStyle(AuraTheme.textSecondary)
                }
            }
            if let asset = gem.photoAsset, UIImage(named: asset) != nil {
                Image(asset).resizable().scaledToFill()
                    .frame(maxWidth: .infinity).frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            if let why = gem.why {
                Text(why).font(.body).foregroundStyle(AuraTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
