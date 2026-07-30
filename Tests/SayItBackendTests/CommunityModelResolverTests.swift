import Foundation
import SayItCore
import Testing
@testable import SayItBackend

@Suite("Community model resolution", .serialized)
struct CommunityModelResolverTests {
    @Test("Remote Kokoro metadata becomes a progressive selectable model")
    func resolvesRemoteKokoroModel() async throws {
        let session = makeStubSession { request in
            if request.url?.path.hasPrefix("/api/models/") == true {
                #expect(
                    request.value(forHTTPHeaderField: "Authorization")
                        == "Bearer test-token"
                )
                return try response(
                    request: request,
                    json: [
                        "sha": "abcdef0123456789",
                        "siblings": [
                            [
                                "rfilename": "model.safetensors",
                                "lfs": [
                                    "sha256": "deadbeef",
                                    "size": 1_500_000_000
                                ]
                            ],
                            [
                                "rfilename": "config.json",
                                "size": 2_048
                            ]
                        ],
                        "cardData": ["license": "apache-2.0"]
                    ]
                )
            }
            return try response(
                request: request,
                json: ["model_type": "kokoro"]
            )
        }
        let resolver = CommunityModelResolver(session: session)

        let model = try await resolver.resolve(
            repository: " acme/Kokoro_Test ",
            revision: " release ",
            token: "test-token"
        )

        #expect(model.id.rawValue == "community-acme-kokoro-test-abcdef01")
        #expect(model.displayName == "Kokoro_Test")
        #expect(model.repository == "acme/Kokoro_Test")
        #expect(model.revision == "abcdef0123456789")
        #expect(model.modelType == "kokoro")
        #expect(model.defaultVoice == "af_heart")
        #expect(model.capabilities.presetVoices)
        #expect(model.capabilities.streaming)
        #expect(model.playbackMode == .progressive)
        #expect(model.estimatedDiskBytes == 1_500_002_048)
        #expect(model.hardwareTier == .mid)
        #expect(model.license.identifier == "apache-2.0")
        #expect(model.stability == .experimental)
    }

    @Test("Remote reference-only and voice-design models map capabilities")
    func resolvesSpecializedRemoteCapabilities() async throws {
        for (type, expectedCloning, expectedDesign) in [
            ("echo_tts", true, false),
            ("omnivoice", false, true)
        ] {
            let session = makeStubSession { request in
                if request.url?.path.hasPrefix("/api/models/") == true {
                    return try response(
                        request: request,
                        json: [
                            "sha": "1234567890abcdef",
                            "siblings": [
                                [
                                    "rfilename": "weights.safetensors",
                                    "size": 3_000_000_000
                                ]
                            ],
                            "cardData": [:]
                        ]
                    )
                }
                return try response(
                    request: request,
                    json: ["architecture": type]
                )
            }
            let model = try await CommunityModelResolver(session: session)
                .resolve(
                    repository: "owner/model",
                    revision: nil,
                    token: nil
                )

            #expect(model.capabilities.voiceCloning == expectedCloning)
            #expect(model.capabilities.voiceDescription == expectedDesign)
            #expect(
                model.capabilities.requiresReferenceAudio == expectedCloning
            )
            #expect(model.hardwareTier == .high)
            #expect(
                model.stability
                    == (expectedCloning ? .unavailable : .experimental)
            )
            #expect(model.license.identifier == "See model card")
        }
    }

    @Test("Remote resolution rejects malformed inputs and responses")
    func rejectsBadRemoteResponses() async {
        let invalidRepository = CommunityModelResolver()
        await #expect(throws: ModelManagerError.self) {
            _ = try await invalidRepository.resolve(
                repository: "not-a-repository",
                revision: nil,
                token: nil
            )
        }

        for scenario in RemoteFailureScenario.allCases {
            let session = makeStubSession { request in
                if request.url?.path.hasPrefix("/api/models/") == true {
                    switch scenario {
                    case .metadataStatus:
                        return (
                            HTTPURLResponse(
                                url: try #require(request.url),
                                statusCode: 503,
                                httpVersion: nil,
                                headerFields: nil
                            )!,
                            Data()
                        )
                    case .metadataJSON:
                        return (
                            HTTPURLResponse(
                                url: try #require(request.url),
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: nil
                            )!,
                            Data("not-json".utf8)
                        )
                    default:
                        return try response(
                            request: request,
                            json: [
                                "sha": "abcdef0123456789",
                                "siblings": [],
                                "cardData": [:]
                            ]
                        )
                    }
                }

                switch scenario {
                case .configStatus:
                    return (
                        HTTPURLResponse(
                            url: try #require(request.url),
                            statusCode: 404,
                            httpVersion: nil,
                            headerFields: nil
                        )!,
                        Data()
                    )
                case .unsupportedType:
                    return try response(
                        request: request,
                        json: ["model_version": "unsupported"]
                    )
                case .configJSON:
                    return (
                        HTTPURLResponse(
                            url: try #require(request.url),
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: nil
                        )!,
                        Data("[]".utf8)
                    )
                default:
                    return try response(
                        request: request,
                        json: ["model_type": "kokoro"]
                    )
                }
            }

            await #expect(throws: (any Error).self) {
                _ = try await CommunityModelResolver(session: session)
                    .resolve(
                        repository: "owner/model",
                        revision: nil,
                        token: nil
                    )
            }
        }
    }

    @Test("Local model resolution inventories files and derives capabilities")
    func resolvesLocalModels() async throws {
        for (type, expectedMode, expectedVoice) in [
            ("kokoro_tts", PlaybackMode.progressive, "af_heart"),
            ("omnivoice", PlaybackMode.buffered, nil),
            ("index_tts", PlaybackMode.buffered, nil)
        ] {
            let fixture = try TemporaryBackendFixture(
                prefix: "SayItLocalModelTests"
            )
            defer { fixture.remove() }
            let source = fixture.root.appending(
                path: "Imported-\(type)",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: source.appending(path: "nested"),
                withIntermediateDirectories: true
            )
            try JSONSerialization.data(
                withJSONObject: ["model_type": type]
            ).write(to: source.appending(path: "config.json"))
            try Data(repeating: 7, count: 128).write(
                to: source.appending(path: "nested/model.safetensors")
            )

            let model = try await CommunityModelResolver().resolveLocal(
                directory: source
            )
            #expect(model.displayName == "Imported-\(type)")
            #expect(model.repository == "local-import")
            #expect(model.modelType == type)
            #expect(model.playbackMode == expectedMode)
            #expect(model.defaultVoice == expectedVoice)
            #expect(model.estimatedDiskBytes >= 128)
            #expect(model.id.rawValue.hasPrefix("community-local-"))
            #expect(model.revision.count == 64)
            #expect(
                model.capabilities.requiresReferenceAudio
                    == (type == "index_tts")
            )
            #expect(
                model.capabilities.voiceDescription == (type == "omnivoice")
            )
        }
    }

    @Test("Local resolution accepts alternate type keys")
    func localAlternateTypeKeys() async throws {
        for key in ["architecture", "model_version"] {
            let fixture = try TemporaryBackendFixture(
                prefix: "SayItLocalModelTests"
            )
            defer { fixture.remove() }
            try JSONSerialization.data(
                withJSONObject: [key: "qwen3_tts"]
            ).write(
                to: fixture.root.appending(path: "config.json")
            )
            try Data([1]).write(
                to: fixture.root.appending(path: "weights.safetensors")
            )

            let model = try await CommunityModelResolver()
                .resolveLocal(directory: fixture.root)
            #expect(model.modelType == "qwen3_tts")
        }
    }

    @Test("Local resolution rejects unsupported, incomplete, and linked models")
    func rejectsUnsafeLocalModels() async throws {
        let unsupported = try TemporaryBackendFixture(
            prefix: "SayItLocalModelTests"
        )
        defer { unsupported.remove() }
        try JSONSerialization.data(
            withJSONObject: ["model_type": "unknown"]
        ).write(to: unsupported.root.appending(path: "config.json"))
        try Data([1]).write(
            to: unsupported.root.appending(path: "weights.safetensors")
        )
        await #expect(throws: ModelManagerError.self) {
            _ = try await CommunityModelResolver().resolveLocal(
                directory: unsupported.root
            )
        }

        let missingWeights = try TemporaryBackendFixture(
            prefix: "SayItLocalModelTests"
        )
        defer { missingWeights.remove() }
        try JSONSerialization.data(
            withJSONObject: ["model_type": "kokoro"]
        ).write(to: missingWeights.root.appending(path: "config.json"))
        await #expect(throws: ModelManagerError.self) {
            _ = try await CommunityModelResolver().resolveLocal(
                directory: missingWeights.root
            )
        }

        let linked = try TemporaryBackendFixture(
            prefix: "SayItLocalModelTests"
        )
        defer { linked.remove() }
        try JSONSerialization.data(
            withJSONObject: ["model_type": "kokoro"]
        ).write(to: linked.root.appending(path: "config.json"))
        let outside = linked.root.deletingLastPathComponent().appending(
            path: "\(UUID().uuidString).safetensors"
        )
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data([1]).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: linked.root.appending(path: "weights.safetensors"),
            withDestinationURL: outside
        )
        await #expect(throws: ModelManagerError.self) {
            _ = try await CommunityModelResolver().resolveLocal(
                directory: linked.root
            )
        }
    }
}

private enum RemoteFailureScenario: CaseIterable, Sendable {
    case metadataStatus
    case metadataJSON
    case configStatus
    case configJSON
    case unsupportedType
}

private func makeStubSession(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    StubURLProtocol.setHandler(handler)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func response(
    request: URLRequest,
    json: Any
) throws -> (HTTPURLResponse, Data) {
    let url = try #require(request.url)
    return (
        HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!,
        try JSONSerialization.data(withJSONObject: json)
    )
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler:
        (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    static func setHandler(
        _ newHandler:
            @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        lock.withLock {
            handler = newHandler
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let current = Self.lock.withLock { Self.handler }
            let handler = try #require(current)
            let (response, data) = try handler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
