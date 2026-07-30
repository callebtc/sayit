import Foundation
import Hummingbird
import SayItBackend
import SayItProtocol
import Yams

public final class SayItHTTPServer: Sendable {
    let backend: SayItBackendService
    let rateLimiter = APIRateLimiter()
    let idempotencyStore = IdempotencyStore()
    let openAPIJSON: Data
    let port: Int

    public init(
        backend: SayItBackendService,
        port: Int
    ) throws {
        self.backend = backend
        self.port = port
        guard (1_024...65_535).contains(port) else {
            throw HTTPAPIError(
                status: 400,
                code: "settings.invalid_http_port",
                message: "The HTTP port must be between 1024 and 65535."
            )
        }
        openAPIJSON = try Self.loadOpenAPIJSON()
    }

    public func run() async throws {
        let router = Router()
        registerSystemRoutes(on: router)
        registerJobRoutes(on: router)
        registerPlaybackRoutes(on: router)
        registerModelRoutes(on: router)
        registerVoiceRoutes(on: router)
        registerHistoryRoutes(on: router)
        registerSettingsRoutes(on: router)
        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname("127.0.0.1", port: port),
                serverName: "SayIt"
            )
        )
        try await app.runService()
    }

    private static func loadOpenAPIJSON() throws -> Data {
        #if SWIFT_PACKAGE
        let resourceBundle = Bundle.module
        #else
        let resourceBundle = Bundle(for: SayItHTTPServer.self)
        #endif
        guard let url = resourceBundle.url(
            forResource: "openapi",
            withExtension: "yaml"
        ) else {
            throw HTTPAPIError(
                status: 500,
                code: "openapi.missing",
                message: "The OpenAPI document is missing."
            )
        }
        let yaml = try String(contentsOf: url, encoding: .utf8)
        guard let object = try Yams.load(yaml: yaml),
              JSONSerialization.isValidJSONObject(object) else {
            throw HTTPAPIError(
                status: 500,
                code: "openapi.invalid",
                message: "The OpenAPI document could not be loaded."
            )
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }
}
