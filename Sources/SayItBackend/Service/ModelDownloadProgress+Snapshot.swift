import SayItCore
import SayItProtocol

extension ModelDownloadProgress {
    var serviceSnapshot: DownloadSnapshot {
        DownloadSnapshot(
            modelID: modelID.rawValue,
            state: state.rawValue,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            bytesPerSecond: Double(bytesPerSecond)
        )
    }
}
