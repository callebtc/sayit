import SwiftUI

extension View {
    func sayItCard(padding: Double = DesignTokens.standardSpacing) -> some View {
        modifier(SayItCardStyle(padding: padding))
    }
}

private struct SayItCardStyle: ViewModifier {
    let padding: Double

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .quaternary.opacity(0.55),
                in: .rect(cornerRadius: DesignTokens.cardCornerRadius)
            )
    }
}

struct HoverRowButtonStyle: ButtonStyle {
    var expands = true
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: expands ? .infinity : nil, alignment: .leading)
            .padding(.horizontal, DesignTokens.compactSpacing)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.rowCornerRadius)
                    .fill(.primary.opacity(fillOpacity(isPressed: configuration.isPressed)))
            }
            .contentShape(.rect)
            .onHover { hovering in
                withAnimation(DesignTokens.quickAnimation) {
                    isHovering = hovering
                }
            }
    }

    private func fillOpacity(isPressed: Bool) -> Double {
        if isPressed { return 0.14 }
        return isHovering ? 0.08 : 0
    }
}

extension ButtonStyle where Self == HoverRowButtonStyle {
    static var sayItRow: HoverRowButtonStyle { HoverRowButtonStyle() }

    static var sayItInline: HoverRowButtonStyle {
        HoverRowButtonStyle(expands: false)
    }
}

struct CircularIconButtonStyle: ButtonStyle {
    var size: Double = 28
    var prominent = false
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.44, weight: .semibold))
            .frame(width: size, height: size)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background {
                Circle()
                    .fill(background(isPressed: configuration.isPressed))
            }
            .contentShape(Circle())
            .onHover { hovering in
                withAnimation(DesignTokens.quickAnimation) {
                    isHovering = hovering
                }
            }
    }

    private func background(isPressed: Bool) -> Color {
        if prominent {
            return .accentColor.opacity(
                isPressed ? 0.72 : (isHovering ? 0.85 : 1)
            )
        }
        return .primary.opacity(
            isPressed ? 0.16 : (isHovering ? 0.11 : 0.07)
        )
    }
}

struct SayItBadge: View {
    let title: String
    var tint: Color = .accentColor

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: .capsule)
            .foregroundStyle(tint)
    }
}
