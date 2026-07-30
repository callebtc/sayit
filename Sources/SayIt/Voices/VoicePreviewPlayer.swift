@preconcurrency import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class VoicePreviewPlayer {
    private var player: AVAudioPlayer?
    private(set) var isPlaying = false
    private(set) var playingID: UUID?

    func play(data: Data, id: UUID? = nil) throws {
        stop()
        let player = try AVAudioPlayer(data: data)
        player.prepareToPlay()
        guard player.play() else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.player = player
        isPlaying = true
        playingID = id
        Task { [weak self, weak player] in
            while let player, player.isPlaying {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, self.player === player else { return }
            self.player = nil
            self.isPlaying = false
            self.playingID = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        playingID = nil
    }
}
