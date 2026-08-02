import SwiftUI

struct VoiceGenerationButton: View {
    let title: String
    let systemImage: String
    var generatingTitle: String = "Generating…"
    var isGenerating = false
    var completedCount = 0
    var totalCount = 0
    var isDisabled = false
    let action: () -> Void
    var onCancel: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: DesignTokens.standardSpacing) {
            Button(action: action) {
                HStack(spacing: DesignTokens.standardSpacing) {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 26, height: 26)
                        .background(
                            Color.accentColor.opacity(0.12),
                            in: .rect(cornerRadius: 7)
                        )
                        .contentTransition(.symbolEffect(.replace.offUp))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(isGenerating ? generatingTitle : title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                            .contentTransition(.opacity)
                        if isGenerating, totalCount > 0 {
                            ProgressView(
                                value: Double(completedCount),
                                total: Double(totalCount)
                            )
                            .progressViewStyle(.linear)
                            .tint(.accentColor)
                            .transition(
                                .opacity.combined(with: .move(edge: .top))
                            )
                        }
                    }

                    Spacer()

                    if isGenerating, totalCount > 0 {
                        Text(
                            "\(min(completedCount + 1, totalCount)) of \(totalCount)"
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(
                            .numericText(value: Double(completedCount))
                        )
                        .transition(.opacity)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.sayItRow)
            .disabled(isDisabled || isGenerating)

            if isGenerating, let onCancel {
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .animation(DesignTokens.smoothAnimation, value: isGenerating)
        .animation(DesignTokens.smoothAnimation, value: completedCount)
        .animation(DesignTokens.smoothAnimation, value: systemImage)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isGenerating ? generatingTitle : title)
        .accessibilityAddTraits(.isButton)
    }
}
