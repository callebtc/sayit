import Foundation
import SayItProtocol

enum CLIOutput {
    static func standard(_ string: String) {
        FileHandle.standardOutput.write(Data("\(string)\n".utf8))
    }

    static func status(_ string: String) {
        FileHandle.standardError.write(Data("\(string)\n".utf8))
    }

    static func json<Value: Encodable>(_ value: Value) throws {
        let data = try SayItWireCodec.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
