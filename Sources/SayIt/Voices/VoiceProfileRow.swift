import AppKit
import SayItProtocol
import SwiftUI

struct VoiceProfileRow: View {
    let profile: VoiceProfileSnapshot
    let isSelected: Bool
    let isModelInstalled: Bool
    let onSelect: () -> Void
    let onTest: () -> Void
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
        onTest: @escaping () -> Void,
        onRename: @escaping (String) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.profile = profile
        self.isSelected = isSelected
        self.isModelInstalled = isModelInstalled
        self.onSelect = onSelect
        self.onTest = onTest
        self.onRename = onRename
        self.onDelete = onDelete
        _name = State(initialValue: profile.displayName)
    }

    var body: some View {
        HStack(spacing: DesignTokens.standardSpacing) {
            rowContent
                .contentShape(.rect)
                .onTapGesture {
                    guard canUse else { return }
                    onSelect()
                }
                .onHover { hovering in
                    guard canUse else { return }
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Use voice \(profile.displayName)")
                .accessibilityHint(
                    canUse
                        ? "Selects this voice for speech"
                        : isSelected
                            ? "This voice is selected"
                            : "Reinstall the model to use this voice"
                )

            if !isRenaming {
                Menu("Voice actions", systemImage: "ellipsis.circle") {
                    Button(
                        "Test Voice",
                        systemImage: "speaker.wave.2",
                        action: onTest
                    )
                    .disabled(!isModelInstalled)
                    Button("Rename", action: beginRename)
                    Button(
                        "Delete",
                        systemImage: "trash",
                        role: .destructive,
                        action: confirmDelete
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .labelStyle(.iconOnly)
            }
        }
        .padding(.vertical, 2)
        .animation(DesignTokens.smoothAnimation, value: isRenaming)
        .animation(DesignTokens.smoothAnimation, value: isSelected)
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

    private var rowContent: some View {
        HStack(spacing: DesignTokens.standardSpacing) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(
                    isSelected
                        ? Color.accentColor
                        : Color.secondary.opacity(0.5)
                )
                .contentTransition(.symbolEffect(.replace.offUp))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                if isRenaming {
                    HStack(spacing: DesignTokens.compactSpacing) {
                        TextField("Voice name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 140)
                            .onSubmit(saveRename)
                        Button("Save", action: saveRename)
                            .controlSize(.small)
                        Button("Cancel", action: cancelRename)
                            .controlSize(.small)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(profile.displayName)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                    SayItBadge(
                        title: profile.origin == .generated
                            ? "Discovered"
                            : "Cloned",
                        tint: profile.origin == .generated
                            ? .accentColor
                            : .indigo
                    )
                }
            }

            Spacer()
        }
    }

    private var canUse: Bool {
        isModelInstalled && !isSelected && !isRenaming
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
