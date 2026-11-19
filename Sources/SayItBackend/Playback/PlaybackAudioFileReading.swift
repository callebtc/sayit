@MainActor
protocol PlaybackAudioFileReading: AnyObject {
    var sampleRate: Double { get }
    func readNextChunk() throws -> [Float]?
}
