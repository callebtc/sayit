import Foundation

@MainActor
public protocol PlaybackControlling: AnyObject {
    func enqueue(_ chunk: AudioChunk) throws
    func play()
    func pause()
    func stop()
    func seek(to seconds: TimeInterval)
    func skip(by seconds: TimeInterval)
}
