import Foundation

public struct DownloadSpeedMeter: Sendable {
    public private(set) var bytesPerSecond: Int64 = 0

    private var windowStart: ContinuousClock.Instant?
    private var windowStartBytes: Int64 = 0

    public init() {}

    public mutating func record(
        totalBytes: Int64,
        at now: ContinuousClock.Instant = .now
    ) -> Bool {
        guard let start = windowStart else {
            windowStart = now
            windowStartBytes = totalBytes
            return true
        }
        let interval = start.duration(to: now)
        let seconds = Double(interval.components.seconds)
            + Double(interval.components.attoseconds) / 1e18
        guard seconds >= 1 else { return false }
        bytesPerSecond = Int64(
            Double(max(totalBytes - windowStartBytes, 0)) / seconds
        )
        windowStart = now
        windowStartBytes = totalBytes
        return true
    }
}
