import Foundation
import SayItBackend
import SayItProtocol
import SayItXPC

final class SayItXPCExportedService: NSObject, SayItXPCProtocol {
    private let backend: SayItBackendService

    init(backend: SayItBackendService) {
        self.backend = backend
    }

    func perform(
        _ requestData: Data,
        withReply reply: @escaping @Sendable (Data) -> Void
    ) {
        Task { [backend] in
            let response: ServiceResponse
            do {
                let request = try SayItWireCodec.decode(
                    ServiceRequest.self,
                    from: requestData
                )
                response = await backend.handle(request)
            } catch {
                response = .failure(
                    ServiceFailure(
                        code: "protocol.invalid_request",
                        message: "The service request could not be decoded."
                    )
                )
            }
            let data = (try? SayItWireCodec.encode(response)) ?? Data()
            reply(data)
        }
    }
}
