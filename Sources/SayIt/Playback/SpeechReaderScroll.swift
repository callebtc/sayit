import Foundation

/// Use measured viewport coordinates, independent of lazy-stack height estimates.
enum SpeechReaderScroll {
    static func targetOffset(
        wordFrame: CGRect, viewportHeight: Double, contentOffset: Double
    ) -> Double? {
        guard viewportHeight.isFinite, viewportHeight > 1,
              contentOffset.isFinite, wordFrame.minY.isFinite,
              wordFrame.maxY.isFinite, wordFrame.height > 0 else { return nil }
        let top = viewportHeight * 0.22
        let bottom = viewportHeight * 0.72
        guard wordFrame.minY < top || wordFrame.maxY > bottom else { return nil }
        let target = max(0, contentOffset + wordFrame.midY - viewportHeight * 0.42)
        return abs(target - contentOffset) > 1 ? target : nil
    }
}
