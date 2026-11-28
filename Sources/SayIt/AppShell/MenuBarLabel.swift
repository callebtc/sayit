import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frameIndex = 0

    private var animation: MenuBarIconAnimation {
        MenuBarIconAnimation(playbackState: state.playback.state)
    }

    var body: some View {
        icon
            .overlay(alignment: .topTrailing) {
                if state.errorMessage != nil {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if state.updates.hasUpdate {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 9))
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel("Say It")
            .accessibilityValue(
                state.updates.hasUpdate
                    ? String(localized: "Update available. \(state.statusText)")
                    : state.statusText
            )
            .background {
                AppWindowCoordinator()
            }
            .task(id: AnimationKey(animation: animation, reduceMotion: reduceMotion)) {
                await runAnimation()
            }
    }

    private var icon: some View {
        iconImage
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(
                width: MenuBarIconRenderer.canvasSize.width,
                height: MenuBarIconRenderer.canvasSize.height
            )
    }

    private var iconImage: Image {
        guard animation.isAnimated else {
            return MenuBarIconRenderer.frames(for: .still)?.first.map(Image.init(nsImage:))
                ?? Image("MenuBarIcon")
        }
        if reduceMotion,
           let still = MenuBarIconRenderer.image(for: animation.reducedMotionFrame) {
            return Image(nsImage: still)
        }
        guard let frames = MenuBarIconRenderer.frames(for: animation), !frames.isEmpty else {
            return Image("MenuBarIcon")
        }
        return Image(nsImage: frames[frameIndex % frames.count])
    }

    private func runAnimation() async {
        frameIndex = 0
        guard animation.isAnimated, !reduceMotion else { return }
        let interval = animation.frameInterval
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            frameIndex = (frameIndex + 1) % animation.frameCount
        }
    }
}

private struct AnimationKey: Equatable {
    let animation: MenuBarIconAnimation
    let reduceMotion: Bool
}
