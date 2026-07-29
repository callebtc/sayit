import Foundation
import Hummingbird
import SayItProtocol

extension SayItHTTPServer {
    func registerModelRoutes(on router: Router<BasicRequestContext>) {
        router.get("/v1/models") { request, _ in
            do {
                _ = try await self.authenticate(
                    request,
                    scope: .modelsRead,
                    isWrite: false
                )
                let result = await self.backend.handle(
                    ServiceRequest(command: .models)
                )
                return self.response(for: result)
            } catch let error as HTTPAPIError {
                return self.problemResponse(error)
            } catch {
                return self.problemResponse(
                    HTTPAPIError(
                        status: 500,
                        code: "models.read_failed",
                        message: "Models could not be read."
                    )
                )
            }
        }

        router.post("/v1/models/:id/select") { request, context in
            await self.modelCommand(
                request,
                context: context,
                command: ServiceCommand.selectModel
            )
        }
        router.post("/v1/models/:id/install") { request, context in
            await self.modelCommand(
                request,
                context: context,
                command: ServiceCommand.installModel
            )
        }
        router.delete("/v1/models/:id/install") { request, _ in
            await self.authorizedCommand(
                request,
                scope: .modelsWrite,
                command: .cancelModelInstall
            )
        }
        router.delete("/v1/models/:id") { request, context in
            await self.modelCommand(
                request,
                context: context,
                command: ServiceCommand.removeModel
            )
        }
        router.post("/v1/models/imports") { request, _ in
            do {
                _ = try await self.authenticate(
                    request,
                    scope: .modelsWrite,
                    isWrite: true
                )
                let archive = try await self.receiveUpload(request)
                defer {
                    try? FileManager.default.removeItem(at: archive)
                }
                let extraction = try await ModelArchiveImporter().extract(
                    archive
                )
                defer {
                    try? FileManager.default.removeItem(
                        at: extraction.cleanupDirectory
                    )
                }
                try await self.backend.importUploadedModel(
                    from: extraction.modelDirectory
                )
                return Response(status: .accepted)
            } catch let error as HTTPAPIError {
                return self.problemResponse(error)
            } catch let failure as ServiceFailure {
                return self.problemResponse(
                    HTTPAPIError(
                        status: 400,
                        code: failure.code,
                        message: failure.message
                    )
                )
            } catch {
                return self.problemResponse(
                    HTTPAPIError(
                        status: 400,
                        code: "models.import_failed",
                        message: error.localizedDescription
                    )
                )
            }
        }
    }

    private func modelCommand(
        _ request: Request,
        context: BasicRequestContext,
        command: (String) -> ServiceCommand
    ) async -> Response {
        do {
            let id = try stringID(from: context)
            return await authorizedCommand(
                request,
                scope: .modelsWrite,
                command: command(id)
            )
        } catch let error as HTTPAPIError {
            return problemResponse(error)
        } catch {
            return problemResponse(
                HTTPAPIError(
                    status: 500,
                    code: "models.command_failed",
                    message: "The model command could not be completed."
                )
            )
        }
    }
}
