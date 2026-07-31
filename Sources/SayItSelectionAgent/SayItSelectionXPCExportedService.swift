import Foundation
import SayItProtocol
import SayItXPC

final class SayItSelectionXPCExportedService: NSObject,
    SelectionXPCProtocol, @unchecked Sendable {
    private let reader = SelectedTextReader()

    func perform(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data) -> Void
    ) {
        let response: SelectionServiceResponse
        do {
            switch try SayItWireCodec.decode(
                SelectionServiceRequest.self,
                from: request
            ) {
            case .authorizationStatus:
                response = .authorizationStatus(
                    isTrusted: reader.isAuthorized
                )
            case .requestAuthorization:
                response = .authorizationStatus(
                    isTrusted: reader.requestAuthorization()
                )
            case .selectedText:
                response = reader.selectedText()
            }
        } catch {
            response = .unavailable
        }

        guard let data = try? SayItWireCodec.encode(response) else {
            reply(Data())
            return
        }
        reply(data)
    }
}
