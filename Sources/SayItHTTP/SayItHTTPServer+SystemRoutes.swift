import Foundation
import Hummingbird
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
                _ = try await self.authenticate(
                    request,
                    scope: .stateRead,
                    isWrite: false
                )
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
                        var lastRevision = requestedRevision
                        while !Task.isCancelled {
                            let events = await backend.events(
                                after: lastRevision
                            )
                            for event in events {
                                let data = try SayItWireCodec.encode(event)
                                let json = String(decoding: data, as: UTF8.self)
                                let payload = """
                                id: \(event.id)
                                event: snapshot
                                data: \(json)


                                """
                                try await writer.write(
                                    ByteBuffer(string: payload)
                                )
                                lastRevision = event.id
                            }
                            try await Task.sleep(for: .milliseconds(100))
                        }
                        try await writer.finish(nil)
                    }
                )
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
}
