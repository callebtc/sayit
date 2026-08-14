import SwiftUI

struct VolumeControlView: View {
    static let minimumVolume = 0.0
    static let maximumVolume = 2.0

    @Environment(AppState.self) private var state
    @Binding var isActive: Bool

    var body: some View {
        HStack(spacing: DesignTokens.standardSpacing) {
            Image(systemName: Self.symbol(for: state.playback.volume))
                .font(.system(size: 28 * 0.44, weight: .semibold))
                .frame(width: 28, height: 28)
                .background {
                    Circle().fill(.primary.opacity(0.07))
                }
                .contentTransition(.symbolEffect(.replace.offUp))
                .animation(
                    DesignTokens.quickAnimation,
                    value: Self.symbol(for: state.playback.volume)
                )

            Slider(value: sliderPosition, in: 0...1) {
                Text("Playback volume")
            }

            Text(formattedVolume)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .contentShape(.rect)
        .onExitCommand {
            isActive = false
        }
        .help("Playback volume")
    }

    static func symbol(for volume: Double) -> String {
        switch volume {
        case 0:
            return "speaker.slash.fill"
        case ..<0.75:
            return "speaker.wave.1.fill"
        case ..<1.5:
            return "speaker.wave.2.fill"
        default:
            return "speaker.wave.3.fill"
        }
    }

    private var formattedVolume: String {
        "\(Int((state.playback.volume * 100).rounded()))%"
    }

    private var sliderPosition: Binding<Double> {
        Binding(
            get: { Self.position(forVolume: state.playback.volume) },
            set: { setVolume(Self.volume(forPosition: $0)) }
        )
    }

    static func position(forVolume volume: Double) -> Double {
        if volume <= 1 {
            return (volume - minimumVolume) / (1 - minimumVolume) * 0.5
        }
        return 0.5 + (volume - 1) / (maximumVolume - 1) * 0.5
    }

    static func volume(forPosition position: Double) -> Double {
        if position <= 0.5 {
            return minimumVolume + position * 2 * (1 - minimumVolume)
        }
        return 1 + (position - 0.5) * 2 * (maximumVolume - 1)
    }

    private func setVolume(_ volume: Double) {
        let clamped = min(
            max(volume, Self.minimumVolume),
            Self.maximumVolume
        )
        state.playback.volume = clamped
        state.settings.volume = clamped
    }
}
