import Hummingbird
import SayItProtocol

extension SayItHTTPServer {
    func registerSettingsRoutes(on router: Router<BasicRequestContext>) {
        router.get("/v1/settings") { request, _ in
            do {
                _ = try await self.authenticate(
                    request,
                    scope: .settingsRead,
                    isWrite: false
                )
                let result = await self.backend.handle(
                    ServiceRequest(command: .snapshot)
                )
                guard case .snapshot(let snapshot) = result else {
                    return self.response(for: result)
                }
                return self.jsonResponse(snapshot.settings)
            } catch let error as HTTPAPIError {
                return self.problemResponse(error)
            } catch {
                return self.problemResponse(
                    HTTPAPIError(
                        status: 500,
                        code: "settings.read_failed",
                        message: "Settings could not be read."
                    )
                )
            }
        }
        router.patch("/v1/settings") { request, _ in
            await self.authorizedDecodedCommand(
                request,
                scope: .settingsWrite,
                body: BackendSettingsSnapshot.self
            ) {
                .updateSettings($0)
            }
        }

        router.get("/v1/diagnostics") { request, _ in
            do {
                _ = try await self.authenticate(
                    request,
                    scope: .diagnosticsRead,
                    isWrite: false
                )
                let result = await self.backend.handle(
                    ServiceRequest(command: .diagnostics)
                )
                return self.response(for: result)
            } catch let error as HTTPAPIError {
                return self.problemResponse(error)
            } catch {
                return self.problemResponse(
                    HTTPAPIError(
                        status: 500,
                        code: "diagnostics.read_failed",
                        message: "Diagnostics could not be read."
                    )
                )
            }
        }
        router.delete("/v1/diagnostics") { request, _ in
            await self.authorizedCommand(
                request,
                scope: .diagnosticsWrite,
                command: .clearDiagnostics
            )
        }
        router.get("/v1/diagnostics/export") { request, _ in
            await self.authorizedCommand(
                request,
                scope: .diagnosticsRead,
                command: .exportDiagnostics,
                isWrite: false,
                successStatus: .ok
            )
        }
    }
}
