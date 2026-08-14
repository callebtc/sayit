import Hummingbird
import SayItProtocol

enum ServiceEventSSEWriter {
    static func write(
        _ response: ServiceResponse,
        lastRevision: inout UInt64,
        to writer: inout any ResponseBodyWriter
    ) async throws {
        switch response {
        case .events(let events):
            guard !events.isEmpty else {
                try await writer.write(ByteBuffer(string: ": heartbeat\n\n"))
                return
            }

            for event in events {
                let data = try SayItWireCodec.encode(event)
                let json = String(decoding: data, as: UTF8.self)
                let payload = """
                id: \(event.id)
                event: snapshot
                data: \(json)


                """
                try await writer.write(ByteBuffer(string: payload))
                lastRevision = event.id
            }
        case .failure(let failure):
            throw failure
        default:
            throw ServiceFailure(
                code: "events.invalid_response",
                message: "The service returned an invalid event response."
            )
        }
    }
}
