import Testing
@testable import SayIt

@Suite("Volume control view")
struct VolumeControlViewTests {
    @Test("Slider spans silence through double volume")
    @MainActor
    func sliderVolumeRange() {
        #expect(VolumeControlView.position(forVolume: 0) == 0)
        #expect(VolumeControlView.position(forVolume: 1) == 0.5)
        #expect(VolumeControlView.position(forVolume: 2) == 1)

        #expect(VolumeControlView.volume(forPosition: 0) == 0)
        #expect(VolumeControlView.volume(forPosition: 0.5) == 1)
        #expect(VolumeControlView.volume(forPosition: 1) == 2)
    }

    @Test("Silence uses the muted speaker symbol")
    @MainActor
    func silenceSymbol() {
        #expect(VolumeControlView.symbol(for: 0) == "speaker.slash.fill")
    }
}
