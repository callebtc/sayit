import Hummingbird
import SayItProtocol

extension SayItHTTPServer {
    func authorizedCommand(
        _ request: Request,
        scope: APITokenScope,
        command: ServiceCommand,
        isWrite: Bool = true,
        successStatus: HTTPResponse.Status = .accepted
    ) async -> Response {
        do {
            _ = try await authenticate(
                request,
                scope: scope,
                isWrite: isWrite
            )
            let result = await backend.handle(ServiceRequest(command: command))
            return response(for: result, successStatus: successStatus)
        } catch let error as HTTPAPIError {
            return problemResponse(error)
        } catch {
            return problemResponse(
                HTTPAPIError(
                    status: 500,
                    code: "service.command_failed",
                    message: "The service command failed."
                )
            )
        }
    }

    func authorizedDecodedCommand<Body: Decodable>(
        _ request: Request,
        scope: APITokenScope,
        body: Body.Type,
        makeCommand: (Body) -> ServiceCommand
    ) async -> Response {
        do {
            _ = try await authenticate(request, scope: scope, isWrite: true)
            let decoded = try await decodeBody(body, request: request)
            let result = await backend.handle(
                ServiceRequest(command: makeCommand(decoded))
            )
            return response(for: result, successStatus: .accepted)
        } catch let error as HTTPAPIError {
            return problemResponse(error)
        } catch {
            return problemResponse(
                HTTPAPIError(
                    status: 500,
                    code: "service.command_failed",
                    message: "The service command failed."
                )
            )
        }
    }
}
