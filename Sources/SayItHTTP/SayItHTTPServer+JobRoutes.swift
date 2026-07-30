import Foundation
import Hummingbird
import SayItProtocol

extension SayItHTTPServer {
    func registerJobRoutes(on router: Router<BasicRequestContext>) {
        router.get("/v1/jobs") { request, _ in
            await self.authorizedCommand(
                request,
                scope: .stateRead,
                command: .jobs,
                isWrite: false,
                successStatus: .ok
            )
        }

        router.post("/v1/jobs") { request, _ in
            do {
                let token = try await self.authenticate(
                    request,
                    scope: .speechSubmit,
                    isWrite: true
                )
                let idempotencyKey = request.headers
                    .first { $0.name.canonicalName == "idempotency-key" }
                    .map(\.value)
                if let idempotencyKey {
                    guard !idempotencyKey.isEmpty,
                          idempotencyKey.count <= 128 else {
                        throw HTTPAPIError(
                            status: 400,
                            code: "request.invalid_idempotency_key",
                            message: "Idempotency-Key must contain 1 to 128 characters."
                        )
                    }
                    if let job = await self.idempotencyStore.job(
                        tokenID: token.id,
                        key: idempotencyKey
                    ) {
                        return self.jobResponse(job)
                    }
                }

                let body = try await self.decodeBody(
                    HTTPSubmission.self,
                    request: request
                )
                let submission = try body.serviceSubmission()
                let result = await self.backend.handle(
                    ServiceRequest(command: .submit(submission))
                )
                if case .job(let job) = result, let idempotencyKey {
                    await self.idempotencyStore.store(
                        job,
                        tokenID: token.id,
                        key: idempotencyKey
                    )
                }
                if case .job(let job) = result {
                    return self.jobResponse(job)
                }
                return self.response(for: result, successStatus: .accepted)
            } catch let error as HTTPAPIError {
                return self.problemResponse(error)
            } catch {
                return self.problemResponse(
                    HTTPAPIError(
                        status: 500,
                        code: "job.submission_failed",
                        message: "The speech job could not be submitted."
                    )
                )
            }
        }

        router.get("/v1/jobs/:id") { request, context in
            do {
                _ = try await self.authenticate(
                    request,
                    scope: .stateRead,
                    isWrite: false
                )
                let id = try self.uuid(from: context)
                let result = await self.backend.handle(
                    ServiceRequest(command: .jobs)
                )
                guard case .jobs(let jobs) = result,
                      let job = jobs.first(where: { $0.id == id }) else {
                    throw HTTPAPIError(
                        status: 404,
                        code: "job.not_found",
                        message: "The speech job was not found."
                    )
                }
                return self.jsonResponse(job)
            } catch let error as HTTPAPIError {
                return self.problemResponse(error)
            } catch {
                return self.problemResponse(
                    HTTPAPIError(
                        status: 500,
                        code: "job.read_failed",
                        message: "The speech job could not be read."
                    )
                )
            }
        }

        router.delete("/v1/jobs/:id") { request, context in
            do {
                let id = try self.uuid(from: context)
                return await self.authorizedCommand(
                    request,
                    scope: .speechSubmit,
                    command: .cancelJob(id),
                    successStatus: .accepted
                )
            } catch let error as HTTPAPIError {
                return self.problemResponse(error)
            }
        }

        router.post("/v1/jobs/:id/confirm") { request, context in
            do {
                let id = try self.uuid(from: context)
                return await self.authorizedCommand(
                    request,
                    scope: .speechSubmit,
                    command: .confirmJob(id),
                    successStatus: .accepted
                )
            } catch let error as HTTPAPIError {
                return self.problemResponse(error)
            }
        }
    }

    private func jobResponse(_ job: SpeechJob) -> Response {
        var response = jsonResponse(job, status: .accepted)
        response.headers[.location] = "/v1/jobs/\(job.id.uuidString.lowercased())"
        return response
    }
}
