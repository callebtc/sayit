import AppKit
import SayItProtocol
import SwiftUI

struct VoiceProfileRow: View {
    let profile: VoiceProfileSnapshot
    let isSelected: Bool
    let isModelInstalled: Bool
    let onSelect: () -> Void
    let onTest: () -> Void
    let onCustomize: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let makeDragItem: () -> NSItemProvider

    @State private var name: String
    @State private var isRenaming = false
    @State private var isConfirmingDelete = false
    @FocusState private var renameFocused: Bool

    init(
        profile: VoiceProfileSnapshot,
        isSelected: Bool,
        isModelInstalled: Bool,
        onSelect: @escaping () -> Void,
        onTest: @escaping () -> Void,
        onCustomize: @escaping () -> Void,
        onRename: @escaping (String) -> Void,
        onDelete: @escaping () -> Void,
        makeDragItem: @escaping () -> NSItemProvider
    ) {
        self.profile = profile
        self.isSelected = isSelected
        self.isModelInstalled = isModelInstalled
        self.onSelect = onSelect
        self.onTest = onTest
        self.onCustomize = onCustomize
        self.onRename = onRename
        self.onDelete = onDelete
        self.makeDragItem = makeDragItem
        _name = State(initialValue: profile.displayName)
    }

    var body: some View {
        HStack(spacing: DesignTokens.standardSpacing) {
            if isRenaming {
                rowContent
                    .contentShape(.rect)
                    .accessibilityLabel("Voice name")
            } else {
                rowContent
                    .contentShape(.rect)
                    .onDrag(makeDragItem) {
                        Color.clear.frame(width: 1, height: 1)
                    }
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
            }

            Menu("Voice actions", systemImage: "ellipsis") {
                Button(
                    "Test Voice",
                    systemImage: "speaker.wave.2",
                    action: onTest
                )
                .disabled(!isModelInstalled)
                Button(
                    "Customize…",
                    systemImage: "slider.horizontal.3",
                    action: onCustomize
                )
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
                    TextField("Voice name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .focused($renameFocused)
                        .onSubmit(saveRename)
                        .onExitCommand(perform: cancelRename)
                        .onChange(of: renameFocused) { _, focused in
                            if !focused {
                                saveRename()
                            }
                        }
                        .onAppear {
                            renameFocused = true
                        }
                } else {
                    Text(profile.displayName)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .onTapGesture(count: 2) {
                            beginRename()
                        }
                }
                SayItBadge(
                    title: profile.origin == .generated
                        ? "Discovered"
                        : "Cloned",
                    tint: profile.origin == .generated
                        ? .accentColor
                        : .indigo
                )
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
        guard isRenaming else { return }
        isRenaming = false
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != profile.displayName {
            onRename(name)
        }
        name = profile.displayName
    }

    private func cancelRename() {
        name = profile.displayName
        isRenaming = false
    }

    private func confirmDelete() {
        isConfirmingDelete = true
    }
}
