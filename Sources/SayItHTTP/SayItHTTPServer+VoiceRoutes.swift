import Foundation
import Hummingbird
import SayItProtocol

extension SayItHTTPServer {
    func registerVoiceRoutes(on router: Router<BasicRequestContext>) {
        router.get("/v1/voices") { request, _ in
            do {
                _ = try await self.authenticate(
                    request,
                    scope: .voicesRead,
                    isWrite: false
                )
                let modelID = request.uri.queryParameters["modelID"].map {
                    String($0)
                }
                let result = await self.backend.handle(
                    ServiceRequest(command: .voices(modelID: modelID))
                )
                let modelsResult = await self.backend.handle(
                    ServiceRequest(command: .models)
                )
                let snapshotResult = await self.backend.handle(
                    ServiceRequest(command: .snapshot)
                )
                guard case .voices(let profiles) = result,
                      case .models(let models) = modelsResult,
                      case .snapshot(let snapshot) = snapshotResult else {
                    throw HTTPAPIError(
                        status: 500,
                        code: "voices.invalid_response",
                        message: "The voice catalog could not be assembled."
                    )
                }
                let matchingModels = models.filter {
                    modelID == nil || $0.id == modelID
                }
                let response = HTTPVoiceCatalogResponse(
                    profiles: profiles,
                    models: matchingModels.map {
                        HTTPVoiceModelModes(
                            model: $0,
                            installedModelIDs: Set(
                                snapshot.installedModelIDs
                            ),
                            currentSelection:
                                snapshot.settings.voiceSelections[$0.id]
                        )
                    }
                )
                return self.jsonResponse(response)
            } catch let error as HTTPAPIError {
                return self.problemResponse(error)
            } catch {
                return self.problemResponse(
                    HTTPAPIError(
                        status: 500,
                        code: "voices.read_failed",
                        message: "Saved voices could not be read."
                    )
                )
            }
        }

        router.get("/v1/voices/:id") { request, context in
            do {
                _ = try await self.authenticate(
                    request,
                    scope: .voicesRead,
                    isWrite: false
                )
                let id = try self.uuid(from: context)
                let result = await self.backend.handle(
                    ServiceRequest(command: .voices(modelID: nil))
                )
                guard case .voices(let voices) = result,
                      let voice = voices.first(where: { $0.id == id }) else {
                    throw HTTPAPIError(
                        status: 404,
                        code: "voice.not_found",
                        message: "The saved voice was not found."
                    )
                }
                return self.jsonResponse(voice)
            } catch let error as HTTPAPIError {
                return self.problemResponse(error)
            } catch {
                return self.problemResponse(
                    HTTPAPIError(
                        status: 500,
                        code: "voice.read_failed",
                        message: "The saved voice could not be read."
                    )
                )
            }
        }

        router.post("/v1/voices/:id/select") { request, context in
            await self.voiceCommand(
                request,
                context: context,
                command: ServiceCommand.selectVoice
            )
        }

        router.patch("/v1/voices/:id") { request, context in
            do {
                let id = try self.uuid(from: context)
                return await self.authorizedDecodedCommand(
                    request,
                    scope: .voicesWrite,
                    body: RenameVoiceRequest.self
                ) {
                    .renameVoice(id, name: $0.name)
                }
            } catch let error as HTTPAPIError {
                return self.problemResponse(error)
            } catch {
                return self.problemResponse(
                    HTTPAPIError(
                        status: 500,
                        code: "voice.rename_failed",
                        message: "The saved voice could not be renamed."
                    )
                )
            }
        }

        router.delete("/v1/voices/:id") { request, context in
            await self.voiceCommand(
                request,
                context: context,
                command: ServiceCommand.deleteVoice
            )
        }
    }

    private func voiceCommand(
        _ request: Request,
        context: BasicRequestContext,
        command: (UUID) -> ServiceCommand
    ) async -> Response {
        do {
            let id = try uuid(from: context)
            return await authorizedCommand(
                request,
                scope: .voicesWrite,
                command: command(id)
            )
        } catch let error as HTTPAPIError {
            return problemResponse(error)
        } catch {
            return problemResponse(
                HTTPAPIError(
                    status: 500,
                    code: "voice.command_failed",
                    message: "The voice command could not be completed."
                )
            )
        }
    }
}
