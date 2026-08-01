import Foundation
import Testing
@testable import SayItCore

@Suite("Download speed meter")
struct DownloadSpeedMeterTests {
    @Test("First sample starts the window and reports zero speed")
    func firstSampleStartsWindow() {
        var meter = DownloadSpeedMeter()
        let now = ContinuousClock.now
        let emitted = meter.record(totalBytes: 1_000, at: now)
        #expect(emitted)
        #expect(meter.bytesPerSecond == 0)
    }

    @Test("Samples inside the one-second window do not emit")
    func samplesWithinWindowDoNotEmit() {
        var meter = DownloadSpeedMeter()
        let start = ContinuousClock.now
        _ = meter.record(totalBytes: 0, at: start)
        let emitted = meter.record(
            totalBytes: 500_000,
            at: start.advanced(by: .milliseconds(500))
        )
        #expect(!emitted)
        #expect(meter.bytesPerSecond == 0)
    }

    @Test("Speed averages the bytes transferred across the window")
    func averagesWindowBytes() {
        var meter = DownloadSpeedMeter()
        let start = ContinuousClock.now
        _ = meter.record(totalBytes: 0, at: start)
        let emitted = meter.record(
            totalBytes: 3_000_000,
            at: start.advanced(by: .milliseconds(1_500))
        )
        #expect(emitted)
        #expect(meter.bytesPerSecond == 2_000_000)
    }

    @Test("Windows roll forward after each measurement")
    func windowsRollForward() {
        var meter = DownloadSpeedMeter()
        let start = ContinuousClock.now
        _ = meter.record(totalBytes: 0, at: start)
        _ = meter.record(
            totalBytes: 1_000_000,
            at: start.advanced(by: .seconds(1))
        )
        let emitted = meter.record(
            totalBytes: 5_000_000,
            at: start.advanced(by: .seconds(3))
        )
        #expect(emitted)
        #expect(meter.bytesPerSecond == 2_000_000)
    }

    @Test("Byte counts moving backwards never report negative speed")
    func backwardsBytesClampToZero() {
        var meter = DownloadSpeedMeter()
        let start = ContinuousClock.now
        _ = meter.record(totalBytes: 1_000_000, at: start)
        _ = meter.record(
            totalBytes: 500_000,
            at: start.advanced(by: .seconds(2))
        )
        #expect(meter.bytesPerSecond == 0)
    }
}
