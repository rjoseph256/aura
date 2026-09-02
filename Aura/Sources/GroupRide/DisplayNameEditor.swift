import SwiftUI
import AuraCore
import AuraKit

/// Edits the rider's crew display name — the name other riders see on a group
/// ride's roster. Live-validates via `DisplayName.normalized` (blank and >40
/// grapheme-cluster input can't be saved) and shows a running "characters left"
/// affordance so the 40-character cap never feels like a surprise truncation.
struct DisplayNameEditor: View {
    @Bindable var store: DisplayNameStore
    /// One quiet line above the field saying WHY a name is being asked for. The group-ride
    /// gate passes it; Settings (already titled "Crew name") leaves it nil. Declared BEFORE
    /// `onSaved` so trailing-closure call sites keep resolving.
    var contextLine: String?
    /// Called after a successful save. Defaults to a no-op so the Settings call site
    /// (which just wants persistence) is unaffected; the group-ride "needs a name"
    /// gate (Task 16) uses this to re-invoke the create/join it deferred.
    var onSaved: () -> Void = {}
    /// When true, a successful save pops this pushed editor back to the caller (Settings),
    /// where the crew-name row's inline value — now updated — is the save confirmation.
    /// The group-ride name gate leaves this false: it advances via `onSaved` instead.
    var dismissesOnSave: Bool = false

    @Environment(\.dismiss) private var dismiss

    /// The name is edited in a transient draft and only committed to `store` on a
    /// successful save, so backing out without saving never dirties the value the
    /// Settings row previews. Seeded from the committed name when the editor appears.
    @State private var draft: String = ""
    @State private var didSeedDraft = false
    @State private var isSaving = false
    @State private var saveError: String?
    @FocusState private var isFocused: Bool

    private var remaining: Int { DisplayName.maxGraphemes - draft.count }
    private var isValid: Bool { DisplayName.normalized(draft) != nil }
    private var hintColor: Color {
        remaining < 0 ? AuraTheme.destructive : AuraTheme.textSecondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.md) {
            if let contextLine {
                Text(contextLine)
                    .font(.subheadline)
                    .foregroundStyle(AuraTheme.textSecondary)
            }

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
        .onAppear {
            if !didSeedDraft {
                draft = store.name
                didSeedDraft = true
            }
        }
    }

    private var fieldCard: some View {
        HStack(spacing: AuraTheme.Spacing.sm) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(AuraTheme.textSecondary)
                .font(.body.weight(.medium))

            TextField("", text: $draft, prompt:
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

            if !draft.isEmpty {
                Button {
                    draft = ""
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
                try await store.save(draft)
                onSaved()
                if dismissesOnSave { dismiss() }
            } catch {
                saveError = "Couldn't save — check your connection and try again."
            }
        }
    }
}

#Preview("Default") {
    NavigationStack {
        DisplayNameEditor(store: DisplayNameStore(defaults: UserDefaults(suiteName: "preview.default")!,
                                                   backend: InMemoryGroupRideBackend(),
                                                   seedingFrom: "Jamie Rivera"))
    }
    .preferredColorScheme(.dark)
}

#Preview("Group gate — framed") {
    NavigationStack {
        DisplayNameEditor(store: DisplayNameStore(defaults: UserDefaults(suiteName: "preview.framed")!,
                                                   backend: InMemoryGroupRideBackend(),
                                                   seedingFrom: ""),
                          contextLine: "Pick a crew name — it's how your crew sees you.") {
        }
    }
    .preferredColorScheme(.dark)
}

#Preview("Invalid — empty") {
    let store = DisplayNameStore(defaults: UserDefaults(suiteName: "preview.empty")!,
                                  backend: InMemoryGroupRideBackend())
    store.name = ""
    return NavigationStack {
        DisplayNameEditor(store: store)
    }
    .preferredColorScheme(.dark)
}

#Preview("Invalid — over max") {
    let store = DisplayNameStore(defaults: UserDefaults(suiteName: "preview.overmax")!,
                                  backend: InMemoryGroupRideBackend())
    store.name = String(repeating: "a", count: 55)
    return NavigationStack {
        DisplayNameEditor(store: store)
    }
    .preferredColorScheme(.dark)
}
