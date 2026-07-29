import Foundation
import Hummingbird
import SayItProtocol

extension SayItHTTPServer {
    func registerHistoryRoutes(on router: Router<BasicRequestContext>) {
        router.get("/v1/history") { request, _ in
            await self.historyRead(request)
        }
        router.delete("/v1/history") { request, _ in
            await self.authorizedCommand(
                request,
                scope: .historyWrite,
                command: .clearHistory
            )
        }
        router.get("/v1/history/:id") { request, context in
            do {
                _ = try await self.authenticate(
                    request,
                    scope: .historyRead,
                    isWrite: false
                )
                let id = try self.uuid(from: context)
                let result = await self.backend.handle(
                    ServiceRequest(command: .history)
                )
                guard case .history(let items) = result,
                      let item = items.first(where: { $0.id == id }) else {
                    throw HTTPAPIError(
                        status: 404,
                        code: "history.not_found",
                        message: "The history item was not found."
                    )
                }
                return self.jsonResponse(item)
            } catch let error as HTTPAPIError {
                return self.problemResponse(error)
            } catch {
                return self.problemResponse(
                    HTTPAPIError(
                        status: 500,
                        code: "history.read_failed",
                        message: "The history item could not be read."
                    )
                )
            }
        }
        router.delete("/v1/history/:id") { request, context in
            await self.historyCommand(
                request,
                context: context,
                command: ServiceCommand.deleteHistory
            )
        }
        router.post("/v1/history/:id/replay") { request, context in
            await self.historyCommand(
                request,
                context: context,
                command: ServiceCommand.replayHistory
            )
        }
        router.post("/v1/history/:id/regenerate") { request, context in
            await self.historyCommand(
                request,
                context: context,
                command: ServiceCommand.regenerateHistory
            )
        }
        router.post("/v1/history/:id/pin") { request, context in
            await self.historyCommand(
                request,
                context: context,
                command: ServiceCommand.toggleHistoryPinned
            )
        }
        router.get("/v1/history/:id/audio") { request, context in
            do {
                _ = try await self.authenticate(
                    request,
                    scope: .historyRead,
                    isWrite: false
                )
                let id = try self.uuid(from: context)
                let format = request.uri.queryParameters["format"]
                    .map { String($0) } ?? "m4a"
                let result = await self.backend.handle(
                    ServiceRequest(
                        command: .exportHistory(id, format: format)
                    )
                )
                return self.response(for: result)
            } catch let error as HTTPAPIError {
                return self.problemResponse(error)
            } catch {
                return self.problemResponse(
                    HTTPAPIError(
                        status: 500,
                        code: "history.export_failed",
                        message: "The history item could not be exported."
                    )
                )
            }
        }
    }

    private func historyRead(_ request: Request) async -> Response {
        do {
            _ = try await authenticate(
                request,
                scope: .historyRead,
                isWrite: false
            )
            let result = await backend.handle(
                ServiceRequest(command: .history)
            )
            return response(for: result)
        } catch let error as HTTPAPIError {
            return problemResponse(error)
        } catch {
            return problemResponse(
                HTTPAPIError(
                    status: 500,
                    code: "history.read_failed",
                    message: "History could not be read."
                )
            )
        }
    }

    private func historyCommand(
        _ request: Request,
        context: BasicRequestContext,
        command: (UUID) -> ServiceCommand
    ) async -> Response {
        do {
            let id = try uuid(from: context)
            return await authorizedCommand(
                request,
                scope: .historyWrite,
                command: command(id)
            )
        } catch let error as HTTPAPIError {
            return problemResponse(error)
        } catch {
            return problemResponse(
                HTTPAPIError(
                    status: 500,
                    code: "history.command_failed",
                    message: "The history command could not be completed."
                )
            )
        }
    }
}
