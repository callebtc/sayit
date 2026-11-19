import Foundation
import Hummingbird
import SayItBackend
import SayItProtocol

extension SayItHTTPServer {
    func registerSystemRoutes(on router: Router<BasicRequestContext>) {
        router.get("/v1/health") { request, _ in
            guard self.isAllowedHost(request.head.authority) else {
                return self.invalidHostResponse()
            }
            return self.jsonResponse(
                HealthResponse(
                    status: "ok",
                    protocolVersion: SayItProtocolVersion.current
                )
            )
        }

        router.get("/v1/openapi.json") { request, _ in
            guard self.isAllowedHost(request.head.authority) else {
                return self.invalidHostResponse()
            }
            var headers = HTTPFields()
            headers[.contentType] = "application/json; charset=utf-8"
            headers[.cacheControl] = "no-store"
            return Response(
                status: .ok,
                headers: headers,
                body: .init(byteBuffer: ByteBuffer(bytes: self.openAPIJSON))
            )
        }

        router.get("/v1/state") { request, _ in
            do {
                _ = try await self.authenticate(
                    request,
                    scope: .stateRead,
                    isWrite: false
                )
                let result = await self.backend.handle(
                    ServiceRequest(command: .snapshot)
                )
                return self.response(for: result)
            } catch let error as HTTPAPIError {
                return self.problemResponse(error)
            } catch {
                return self.problemResponse(
                    HTTPAPIError(
                        status: 500,
                        code: "service.state_failed",
                        message: "The service state could not be read."
                    )
                )
            }
        }

        router.get("/v1/events") { request, _ in
            do {
                return try await self.eventStreamResponse(for: request)
            } catch let error as HTTPAPIError {
                return self.problemResponse(error)
            } catch {
                return self.problemResponse(
                    HTTPAPIError(
                        status: 500,
                        code: "events.unavailable",
                        message: "The event stream could not be opened."
                    )
                )
            }
        }
    }

    private func eventStreamResponse(for request: Request) async throws -> Response {
        let metadata = try await authenticate(
            request,
            scope: .stateRead,
            isWrite: false
        )
        let watch = await backend.watchAPITokenRevocation(metadata.id)
        do {
            try await confirmAuthorizedToken(request, scope: .stateRead)
        } catch {
            await watch.finish()
            throw error
        }

        let requestedRevision = request.headers
            .first { $0.name.canonicalName == "last-event-id" }
            .map(\.value)
            .flatMap(UInt64.init) ?? 0
        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream; charset=utf-8"
        headers[.cacheControl] = "no-cache, no-store"
        let backend = self.backend
        return Response(
            status: .ok,
            headers: headers,
            body: .init { writer in
                try await Self.writeEventStream(
                    from: backend,
                    startingAt: requestedRevision,
                    watch: watch,
                    to: &writer
                )
            }
        )
    }

    private static func writeEventStream(
        from backend: SayItBackendService,
        startingAt requestedRevision: UInt64,
        watch: APITokenRevocationWatch,
        to writer: inout any ResponseBodyWriter
    ) async throws {
        var lastRevision = requestedRevision
        var didFinishWriter = false
        do {
            while !Task.isCancelled && !watch.isRevoked {
                let read = await readNextEvents(
                    from: backend,
                    after: lastRevision,
                    watch: watch
                )
                // The read that wakes the stream can already contain state
                // published after revocation. Drop it and end the stream.
                guard !Task.isCancelled, !watch.isRevoked else { break }
                guard case .response(let response) = read else { break }
                try await ServiceEventSSEWriter.write(
                    response,
                    lastRevision: &lastRevision,
                    to: &writer
                )
            }
            didFinishWriter = true
            try await writer.finish(nil)
            await watch.finish()
        } catch {
            if !didFinishWriter {
                try? await writer.finish(nil)
            }
            await watch.finish()
            throw error
        }
    }

    private static func readNextEvents(
        from backend: SayItBackendService,
        after revision: UInt64,
        watch: APITokenRevocationWatch
    ) async -> EventStreamRead {
        await withTaskGroup(of: EventStreamRead.self) { group in
            group.addTask {
                let response = await backend.handle(
                    ServiceRequest(
                        command: .waitForEvents(
                            after: revision,
                            playbackInterval: 1
                        )
                    )
                )
                return .response(response)
            }
            group.addTask {
                await watch.waitUntilRevoked()
                return .revoked
            }
            let next = await group.next() ?? .revoked
            group.cancelAll()
            return next
        }
    }
}

private enum EventStreamRead: Sendable {
    case revoked
    case response(ServiceResponse)
}
