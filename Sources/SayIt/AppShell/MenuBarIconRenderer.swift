import AppKit

/// Draws `MenuBarIconFrame`s as template images sized for the menu bar.
/// Images draw lazily at the screen's backing scale, so they stay sharp.
@MainActor
enum MenuBarIconRenderer {
    /// Height of the logo inside the canvas, matching the `MenuBarIcon` PNGs.
    static let contentHeight: CGFloat = 15
    /// How far the slot's center moves from the logo's bounding box toward
    /// its visual center (0 is the box, 1 the visual center). Going all the
    /// way leaves a wide empty gap on the left next to other menu bar items.
    static let visualCenterWeight: CGFloat = 0.25
    private static let fallbackCanvasSize = CGSize(width: 19, height: 19)

    /// The menu bar item's size. The logo touches one side edge and is
    /// shifted so its center sits partway toward its visual center; the
    /// status item adds the same spacing around it as around other items.
    static var canvasSize: CGSize {
        layout?.canvasSize ?? fallbackCanvasSize
    }

    /// Where the logo's visual center lands, in canvas points.
    static var visualCenterX: CGFloat? {
        guard let glyph = MenuBarGlyph.logo, let layout else { return nil }
        return layout.offset.x + glyph.visualCenterX * layout.scale
    }

    /// The logo's bounds in canvas points.
    static var contentFrame: CGRect? {
        guard let glyph = MenuBarGlyph.logo, let layout else { return nil }
        return glyph.bounds
            .applying(CGAffineTransform(scaleX: layout.scale, y: layout.scale))
            .offsetBy(dx: layout.offset.x, dy: layout.offset.y)
    }

    private static var cache: [MenuBarIconAnimation: [NSImage]] = [:]

    private struct Layout {
        let canvasSize: CGSize
        let scale: CGFloat
        let offset: CGPoint
    }

    private static let layout: Layout? = MenuBarGlyph.logo.map { makeLayout(for: $0) }

    private static func makeLayout(for glyph: MenuBarGlyph) -> Layout {
        let bounds = glyph.bounds
        let scale = contentHeight / bounds.height
        let center = bounds.midX + (glyph.visualCenterX - bounds.midX) * visualCenterWeight
        let halfWidth = max(center - bounds.minX, bounds.maxX - center) * scale
        let canvasSize = CGSize(
            width: (2 * halfWidth).rounded(.up),
            height: fallbackCanvasSize.height
        )
        return Layout(
            canvasSize: canvasSize,
            scale: scale,
            offset: CGPoint(
                x: canvasSize.width / 2 - center * scale,
                y: canvasSize.height / 2 - bounds.midY * scale
            )
        )
    }

    /// Pre-rendered frames for an animation, or `nil` if the logo artwork is
    /// unavailable and callers should fall back to the static asset.
    static func frames(for animation: MenuBarIconAnimation) -> [NSImage]? {
        if let cached = cache[animation] {
            return cached
        }
        guard let glyph = MenuBarGlyph.logo, let layout else { return nil }
        let images = animation.frames.map { image(for: $0, glyph: glyph, layout: layout) }
        cache[animation] = images
        return images
    }

    static func image(for frame: MenuBarIconFrame) -> NSImage? {
        guard let glyph = MenuBarGlyph.logo, let layout else { return nil }
        return image(for: frame, glyph: glyph, layout: layout)
    }

    private static func image(for frame: MenuBarIconFrame, glyph: MenuBarGlyph, layout: Layout) -> NSImage {
        let image = NSImage(size: layout.canvasSize, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(frame, glyph: glyph, layout: layout, in: context)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(
        _ frame: MenuBarIconFrame,
        glyph: MenuBarGlyph,
        layout: Layout,
        in context: CGContext
    ) {
        context.translateBy(x: layout.offset.x, y: layout.offset.y)
        context.scaleBy(x: layout.scale, y: layout.scale)
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
            // A three-quarter arc reads as "busy" even at menu bar size. It
            // is cleared out of the filled head so the template image keeps
            // a single color in light and dark menu bars.
            context.setBlendMode(.clear)
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
