import Foundation
import SayItCore
import SayItProtocol

@MainActor
final class BackendSettingsStore {
    private let fileURL: URL
    private(set) var value: BackendSettingsSnapshot

    init(directory: URL) {
        fileURL = directory.appending(path: "Backend Settings.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.sayIt.decode(
               BackendSettingsSnapshot.self,
               from: data
           ) {
            value = decoded
        } else {
            value = BackendSettingsSnapshot()
        }
    }

    func update(_ settings: BackendSettingsSnapshot) throws {
        guard (1_024...65_535).contains(settings.httpPort) else {
            throw ServiceFailure(
                code: "settings.invalid_http_port",
                message: "The HTTP port must be between 1024 and 65535."
            )
        }
        value = settings
        let data = try JSONEncoder.sayIt.encode(settings)
        try data.write(to: fileURL, options: .atomic)
    }
}
