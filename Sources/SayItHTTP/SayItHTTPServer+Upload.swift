import Foundation
import Hummingbird

extension SayItHTTPServer {
    func receiveUpload(
        _ request: Request,
        limit: Int64 = 20 * 1_024 * 1_024 * 1_024
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "SayIt-Upload-\(UUID().uuidString).tar"
        )
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil
        ) else {
            throw HTTPAPIError(
                status: 500,
                code: "models.upload_storage_failed",
                message: "The model upload could not be stored."
            )
        }
        do {
            let output = try FileHandle(forWritingTo: url)
            defer {
                try? output.close()
            }
            var received: Int64 = 0
            for try await buffer in request.body {
                received += Int64(buffer.readableBytes)
                guard received <= limit else {
                    throw HTTPAPIError(
                        status: 413,
                        code: "models.upload_too_large",
                        message: "The model archive exceeds the 20 GiB limit."
                    )
                }
                try output.write(
                    contentsOf: Data(buffer.readableBytesView)
                )
            }
            guard received > 0 else {
                throw HTTPAPIError(
                    status: 400,
                    code: "models.upload_empty",
                    message: "The model archive is empty."
                )
            }
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
