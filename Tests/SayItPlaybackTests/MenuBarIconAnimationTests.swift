import CoreGraphics
import SayItCore
import Testing
@testable import SayIt

@Suite("Menu bar icon animation")
struct MenuBarIconAnimationTests {
    @Test(
        "Playback states map to the expected animation",
        arguments: [
            (PlaybackState.idle, MenuBarIconAnimation.still),
            (.preparing, .processing),
            (.buffering, .processing),
            (.playing, .speaking),
            (.paused, .still),
            (.finished, .still),
            (.failed, .still),
        ]
    )
    func stateMapping(state: PlaybackState, expected: MenuBarIconAnimation) {
        #expect(MenuBarIconAnimation(playbackState: state) == expected)
    }

    @Test("Processing spins through one full turn per loop")
    func processingFrames() {
        let frames = MenuBarIconAnimation.processing.frames
        #expect(frames.count == MenuBarIconAnimation.processing.frameCount)
        #expect(frames.first == .spinner(turns: 0))
        let turns = frames.compactMap { frame -> Double? in
            if case .spinner(let turns) = frame { return turns }
            return nil
        }
        #expect(turns.count == frames.count)
        #expect(turns == turns.sorted())
        #expect(turns.allSatisfy { (0..<1).contains($0) })
    }

    @Test("Speaking lights each wave in turn from the mouth outward")
    func speakingCascade() {
        let opacities = MenuBarIconAnimation.speaking.frames.map { frame -> [Double] in
            guard case .waves(let opacities) = frame else { return [] }
            return opacities
        }
        #expect(opacities.allSatisfy { $0.count == 3 })

        let brightestFrame = (0..<3).map { wave in
            opacities.indices.max { opacities[$0][wave] < opacities[$1][wave] } ?? -1
        }
        #expect(brightestFrame[0] < brightestFrame[1])
        #expect(brightestFrame[1] < brightestFrame[2])

        let all = opacities.flatMap { $0 }
        #expect(all.allSatisfy {
            (MenuBarIconAnimation.dimWaveOpacity...1).contains($0)
        })
        #expect(all.contains { $0 > 0.9 })
    }

    @Test("Frame lookup wraps around the loop")
    func frameWrapping() {
        let animation = MenuBarIconAnimation.speaking
        #expect(animation.frame(at: animation.frameCount + 2) == animation.frame(at: 2))
    }

    @Test("Still and reduced-motion frames never animate")
    func stillFrames() {
        #expect(!MenuBarIconAnimation.still.isAnimated)
        #expect(MenuBarIconAnimation.still.frames == [.still])
        #expect(MenuBarIconAnimation.speaking.reducedMotionFrame == .still)
        #expect(MenuBarIconAnimation.processing.reducedMotionFrame == .spinner(turns: 0))
    }

    @MainActor
    @Test("The logo splits into a head and three waves, ordered outward")
    func glyphShapes() throws {
        let glyph = try #require(MenuBarGlyph.logo)
        #expect(glyph.waves.count == 3)
        let waveStarts = glyph.waves.map(\.boundingBoxOfPath.minX)
        #expect(waveStarts == waveStarts.sorted())
        #expect(glyph.head.boundingBoxOfPath.maxX < waveStarts[0])
    }

    @MainActor
    @Test("The spinner ring sits entirely inside the head")
    func spinnerPlacement() throws {
        let glyph = try #require(MenuBarGlyph.logo)
        let center = glyph.spinnerCenter
        let edges = [
            glyph.spinnerRadius - glyph.spinnerLineWidth / 2,
            glyph.spinnerRadius + glyph.spinnerLineWidth / 2,
        ]
        for step in 0..<72 {
            let angle = CGFloat(step) / 72 * 2 * .pi
            for radius in edges {
                let point = CGPoint(
                    x: center.x + radius * cos(angle),
                    y: center.y + radius * sin(angle)
                )
                #expect(glyph.head.contains(point), "ring leaves the head at \(point)")
            }
        }
    }

    @MainActor
    @Test("The icon leans toward its visual weight without extra padding")
    func layoutCentersVisualWeight() throws {
        let canvas = MenuBarIconRenderer.canvasSize
        let visualCenter = try #require(MenuBarIconRenderer.visualCenterX)
        let content = try #require(MenuBarIconRenderer.contentFrame)
        // The head outweighs the waves, so the slot's center sits between
        // the visual center and the bounding box's center.
        #expect(visualCenter < canvas.width / 2)
        #expect(canvas.width / 2 < content.midX)
        // The logo fills the slot's width apart from rounding up to a whole
        // point and the shift toward the visual center.
        #expect(content.minX >= -0.001)
        #expect(content.maxX <= canvas.width + 0.001)
        #expect(canvas.width - content.width < 4)
        #expect(abs(content.height - MenuBarIconRenderer.contentHeight) < 0.001)
        #expect(content.minY >= 0 && content.maxY <= canvas.height)
    }

    @MainActor
    @Test("Rendered frames are menu bar sized template images")
    func renderedFrames() throws {
        let size = MenuBarIconRenderer.canvasSize
        #expect(size.height == 19)
        for animation in [MenuBarIconAnimation.still, .processing, .speaking] {
            let frames = try #require(MenuBarIconRenderer.frames(for: animation))
            #expect(frames.count == animation.frameCount)
            #expect(frames.allSatisfy { $0.isTemplate && $0.size == size })
        }
    }
}
