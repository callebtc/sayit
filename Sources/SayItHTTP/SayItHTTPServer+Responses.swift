import Foundation
import Hummingbird
import SayItProtocol

extension SayItHTTPServer {
    func authenticate(
        _ request: Request,
        scope: APITokenScope,
        isWrite: Bool
    ) async throws -> APITokenMetadata {
        guard isAllowedHost(request.head.authority) else {
            throw HTTPAPIError(
                status: 400,
                code: "request.invalid_host",
                message: "The Host header must identify the loopback service."
            )
        }
        guard let authorization = request.headers[.authorization],
              authorization.hasPrefix("Bearer "),
              authorization.count > "Bearer ".count else {
            throw HTTPAPIError(
                status: 401,
                code: "authentication.missing_token",
                message: "Send an API token in the Authorization header."
            )
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        let metadata: APITokenMetadata
        do {
            if let tokenAuthorizer {
                metadata = try await tokenAuthorizer(token, scope)
            } else {
                metadata = try await backend.authorize(
                    token: token,
                    for: scope
                )
            }
        } catch let failure as ServiceFailure {
            throw HTTPAPIError(
                status: failure.code == "authentication.insufficient_scope"
                    ? 403
                    : 401,
                code: failure.code,
                message: failure.message
            )
        }
        let permitted = await rateLimiter.consume(
            key: "\(metadata.id.uuidString):\(isWrite ? "write" : "read")",
            limit: isWrite ? 60 : 600
        )
        guard permitted else {
            throw HTTPAPIError(
                status: 429,
                code: "request.rate_limited",
                message: "Too many requests. Try again in one minute."
            )
        }
        return metadata
    }

    func response(
        for serviceResponse: ServiceResponse,
        successStatus: HTTPResponse.Status = .ok
    ) -> Response {
        switch serviceResponse {
        case .snapshot(let value):
            jsonResponse(value, status: successStatus)
        case .events(let value):
            jsonResponse(value, status: successStatus)
        case .job(let value):
            jsonResponse(value, status: successStatus)
        case .jobs(let value):
            jsonResponse(value, status: successStatus)
        case .models(let value):
            jsonResponse(value, status: successStatus)
        case .voices(let value):
            jsonResponse(value, status: successStatus)
        case .voiceStudio(let value):
            jsonResponse(value, status: successStatus)
        case .history(let value):
            jsonResponse(value, status: successStatus)
        case .diagnostics(let value):
            jsonResponse(value, status: successStatus)
        case .tokens(let value):
            jsonResponse(value, status: successStatus)
        case .createdToken(let value):
            jsonResponse(value, status: successStatus)
        case .file(let value):
            fileResponse(value)
        case .accepted:
            Response(status: successStatus)
        case .failure(let failure):
            problemResponse(
                HTTPAPIError(
                    status: status(for: failure.code),
                    code: failure.code,
                    message: failure.message
                )
            )
        }
    }

    func jsonResponse<Value: Encodable>(
        _ value: Value,
        status: HTTPResponse.Status = .ok
    ) -> Response {
        do {
            let data = try SayItWireCodec.encode(value)
            var headers = HTTPFields()
            headers[.contentType] = "application/json; charset=utf-8"
            headers[.cacheControl] = "no-store"
            return Response(
                status: status,
                headers: headers,
                body: .init(byteBuffer: ByteBuffer(bytes: data))
            )
        } catch {
            return problemResponse(
                HTTPAPIError(
                    status: 500,
                    code: "response.encoding_failed",
                    message: "The response could not be encoded."
                )
            )
        }
    }

    func problemResponse(_ error: HTTPAPIError) -> Response {
        let status = HTTPResponse.Status(code: error.status)
        let problem = APIProblem(
            type: "https://sayit.invalid/problems/\(error.code)",
            title: status.reasonPhrase.isEmpty
                ? "Request failed"
                : status.reasonPhrase,
            status: error.status,
            detail: error.message,
            code: error.code
        )
        let data = (try? SayItWireCodec.encode(problem)) ?? Data()
        var headers = HTTPFields()
        headers[.contentType] = "application/problem+json; charset=utf-8"
        headers[.cacheControl] = "no-store"
        if error.status == 401 {
            headers[.wwwAuthenticate] = "Bearer"
        }
        return Response(
            status: status,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    }

    func fileResponse(_ file: ExportedFile) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = file.contentType
        headers[.contentDisposition] =
            "attachment; filename=\"\(file.filename.replacing("\"", with: ""))\""
        headers[.cacheControl] = "no-store"
        return Response(
            status: .ok,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(bytes: file.data))
        )
    }

    func decodeBody<Value: Decodable>(
        _ type: Value.Type,
        request: Request,
        limit: Int = 1_048_576
    ) async throws -> Value {
        let buffer: ByteBuffer
        do {
            buffer = try await request.body.collect(upTo: limit)
        } catch {
            throw HTTPAPIError(
                status: 413,
                code: "request.body_too_large",
                message: "The request body is too large."
            )
        }
        do {
            return try SayItWireCodec.decode(
                type,
                from: Data(buffer.readableBytesView)
            )
        } catch {
            throw HTTPAPIError(
                status: 400,
                code: "request.invalid_json",
                message: "The request body is not valid JSON."
            )
        }
    }

    func uuid(
        from context: BasicRequestContext
    ) throws -> UUID {
        guard let id = context.parameters.get("id", as: UUID.self) else {
            throw HTTPAPIError(
                status: 400,
                code: "request.invalid_identifier",
                message: "The resource identifier is invalid."
            )
        }
        return id
    }

    func stringID(
        from context: BasicRequestContext
    ) throws -> String {
        guard let id = context.parameters.get("id", as: String.self),
              !id.isEmpty else {
            throw HTTPAPIError(
                status: 400,
                code: "request.invalid_identifier",
                message: "The resource identifier is invalid."
            )
        }
        return id
    }

    func isAllowedHost(_ host: String?) -> Bool {
        guard let host else { return false }
        return host == "127.0.0.1"
            || host == "127.0.0.1:\(port)"
            || host == "localhost"
            || host == "localhost:\(port)"
    }

    func invalidHostResponse() -> Response {
        problemResponse(
            HTTPAPIError(
                status: 400,
                code: "request.invalid_host",
                message: "The Host header must identify the loopback service."
            )
        )
    }

    func status(for code: String) -> Int {
        if code.contains("not_found") || code.contains("unavailable") {
            return 404
        }
        if code.contains("in_progress")
            || code.contains("not_awaiting")
            || code.contains("active_cannot_remove") {
            return 409
        }
        if code.contains("too_long") {
            return 413
        }
        return 400
    }
}
