import AppKit

/// Draws `MenuBarIconFrame`s as template images sized for the menu bar.
/// Images draw lazily at the screen's backing scale, so they stay sharp.
@MainActor
enum MenuBarIconRenderer {
    static let canvasSize = CGSize(width: 19, height: 19)
    /// Matches the logo's placement inside the `MenuBarIcon` PNGs.
    private static let contentRect = CGRect(x: 1, y: 2, width: 17, height: 15)

    private static var cache: [MenuBarIconAnimation: [NSImage]] = [:]

    /// Pre-rendered frames for an animation, or `nil` if the logo artwork is
    /// unavailable and callers should fall back to the static asset.
    static func frames(for animation: MenuBarIconAnimation) -> [NSImage]? {
        if let cached = cache[animation] {
            return cached
        }
        guard let glyph = MenuBarGlyph.logo else { return nil }
        let images = animation.frames.map { image(for: $0, glyph: glyph) }
        cache[animation] = images
        return images
    }

    static func image(for frame: MenuBarIconFrame) -> NSImage? {
        MenuBarGlyph.logo.map { image(for: frame, glyph: $0) }
    }

    private static func image(for frame: MenuBarIconFrame, glyph: MenuBarGlyph) -> NSImage {
        let image = NSImage(size: canvasSize, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(frame, glyph: glyph, in: context)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(_ frame: MenuBarIconFrame, glyph: MenuBarGlyph, in context: CGContext) {
        let bounds = glyph.bounds
        let scale = min(contentRect.width / bounds.width, contentRect.height / bounds.height)
        context.translateBy(
            x: contentRect.midX - bounds.midX * scale,
            y: contentRect.midY - bounds.midY * scale
        )
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(.black)
        context.setStrokeColor(.black)

        context.addPath(glyph.head)
        context.fillPath()

        switch frame {
        case .waves(let opacities):
            for (wave, opacity) in zip(glyph.waves, opacities) {
                context.setAlpha(opacity)
                context.addPath(wave)
                context.fillPath()
            }
        case .spinner(let turns):
            let start = CGFloat(turns) * 2 * .pi
            // A three-quarter arc reads as "busy" even at menu bar size.
            context.setLineWidth(glyph.spinnerLineWidth)
            context.setLineCap(.round)
            context.addArc(
                center: glyph.spinnerCenter,
                radius: glyph.spinnerRadius,
                startAngle: start,
                endAngle: start + .pi * 1.5,
                clockwise: false
            )
            context.strokePath()
        }
    }
}
