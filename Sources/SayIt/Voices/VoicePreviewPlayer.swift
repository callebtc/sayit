@preconcurrency import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class VoicePreviewPlayer {
    private var player: AVAudioPlayer?
    private(set) var isPlaying = false

    func play(data: Data) throws {
        stop()
        let player = try AVAudioPlayer(data: data)
        player.prepareToPlay()
        guard player.play() else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.player = player
        isPlaying = true
        Task { [weak self, weak player] in
            while let player, player.isPlaying {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, self.player === player else { return }
            self.player = nil
            self.isPlaying = false
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }
}
