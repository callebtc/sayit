import SayItProtocol
import SwiftUI

struct VoiceProfileRow: View {
    let profile: VoiceProfileSnapshot
    let isSelected: Bool
    let isModelInstalled: Bool
    let onSelect: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var name: String
    @State private var isRenaming = false
    @State private var isConfirmingDelete = false

    init(
        profile: VoiceProfileSnapshot,
        isSelected: Bool,
        isModelInstalled: Bool,
        onSelect: @escaping () -> Void,
        onRename: @escaping (String) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.profile = profile
        self.isSelected = isSelected
        self.isModelInstalled = isModelInstalled
        self.onSelect = onSelect
        self.onRename = onRename
        self.onDelete = onDelete
        _name = State(initialValue: profile.displayName)
    }

    var body: some View {
        LabeledContent {
            HStack {
                if isRenaming {
                    TextField("Voice name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 140)
                    Button("Save", action: saveRename)
                    Button("Cancel", action: cancelRename)
                } else {
                    Button("Use Voice", action: onSelect)
                        .disabled(!isModelInstalled || isSelected)
                    Menu("Voice actions", systemImage: "ellipsis.circle") {
                        Button("Rename", action: beginRename)
                        Button(
                            "Delete",
                            systemImage: "trash",
                            role: .destructive,
                            action: confirmDelete
                        )
                    }
                    .menuStyle(.borderlessButton)
                }
            }
        } label: {
            VStack(alignment: .leading) {
                Label(
                    profile.displayName,
                    systemImage: isSelected
                        ? "checkmark.circle.fill"
                        : profile.origin == .generated
                            ? "sparkles"
                            : "mic.fill"
                )
                Text(profile.origin == .generated ? "Discovered" : "Recorded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            "Delete \(profile.displayName)?",
            isPresented: $isConfirmingDelete
        ) {
            Button("Delete Voice", role: .destructive, action: onDelete)
        } message: {
            Text(
                "The reference recording will be removed. Existing history audio stays available."
            )
        }
    }

    private func beginRename() {
        name = profile.displayName
        isRenaming = true
    }

    private func saveRename() {
        onRename(name)
        isRenaming = false
    }

    private func cancelRename() {
        name = profile.displayName
        isRenaming = false
    }

    private func confirmDelete() {
        isConfirmingDelete = true
    }
}
