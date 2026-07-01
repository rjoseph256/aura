import SwiftUI
import AuraCore

/// Edits the rider's crew display name — the name other riders see on a group
/// ride's roster. Live-validates via `DisplayName.normalized` (blank and >40
/// grapheme-cluster input can't be saved) and shows a running "characters left"
/// affordance so the 40-character cap never feels like a surprise truncation.
struct DisplayNameEditor: View {
    @Bindable var store: DisplayNameStore

    @State private var isSaving = false
    @State private var saveError: String?
    @FocusState private var isFocused: Bool

    private var remaining: Int { DisplayName.maxGraphemes - store.name.count }
    private var isValid: Bool { store.isValid }
    private var hintColor: Color {
        remaining < 0 ? AuraTheme.destructive : AuraTheme.textSecondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.md) {
            fieldCard

            HStack {
                Text(hintText)
                    .font(.footnote)
                    .foregroundStyle(hintColor)
                Spacer()
                if isSaving {
                    ProgressView().controlSize(.small)
                }
            }

            if let saveError {
                Text(saveError)
                    .font(.footnote)
                    .foregroundStyle(AuraTheme.destructive)
            }

            saveButton
        }
        .padding(AuraTheme.Spacing.lg)
        .background(AuraTheme.background.ignoresSafeArea())
        .navigationTitle("Crew name")
    }

    private var fieldCard: some View {
        HStack(spacing: AuraTheme.Spacing.sm) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(AuraTheme.textSecondary)
                .font(.body.weight(.medium))

            TextField("", text: $store.name, prompt:
                Text("Your name")
                    .foregroundColor(AuraTheme.textPrimary.opacity(0.65))
            )
            .foregroundStyle(AuraTheme.textPrimary)
            .font(.body)
            .focused($isFocused)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.words)
            .submitLabel(.done)
            .onSubmit(save)

            if !store.name.isEmpty {
                Button {
                    store.name = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AuraTheme.textSecondary)
                }
            }
        }
        .padding(AuraTheme.Spacing.md)
        .background(AuraTheme.surface, in: RoundedRectangle(cornerRadius: AuraTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AuraTheme.Radius.md)
                .strokeBorder(borderColor, lineWidth: 1)
        )
    }

    private var borderColor: Color {
        guard !store.name.isEmpty else { return AuraTheme.border }
        return isValid ? AuraTheme.border : AuraTheme.destructive.opacity(0.6)
    }

    private var hintText: String {
        remaining < 0 ? "\(-remaining) over the 40 max" : "\(remaining) of 40 left"
    }

    private var saveButton: some View {
        Button(action: save) {
            Text("Save")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(AuraTheme.accent)
        .foregroundStyle(AuraTheme.onAccent)
        .disabled(!isValid || isSaving)
    }

    private func save() {
        isFocused = false
        guard isValid else { return }
        isSaving = true
        saveError = nil
        Task {
            defer { isSaving = false }
            do {
                try await store.save()
            } catch {
                saveError = "Couldn't save — check your connection and try again."
            }
        }
    }
}

#Preview("Default") {
    NavigationStack {
        DisplayNameEditor(store: DisplayNameStore(defaults: UserDefaults(suiteName: "preview.default")!,
                                                   seedingFrom: "Jamie Rivera"))
    }
    .preferredColorScheme(.dark)
}

#Preview("Invalid — empty") {
    let store = DisplayNameStore(defaults: UserDefaults(suiteName: "preview.empty")!)
    store.name = ""
    return NavigationStack {
        DisplayNameEditor(store: store)
    }
    .preferredColorScheme(.dark)
}

#Preview("Invalid — over max") {
    let store = DisplayNameStore(defaults: UserDefaults(suiteName: "preview.overmax")!)
    store.name = String(repeating: "a", count: 55)
    return NavigationStack {
        DisplayNameEditor(store: store)
    }
    .preferredColorScheme(.dark)
}
