import SayItCore
import SayItProtocol

extension DiagnosticEvent {
    var serviceSnapshot: DiagnosticSnapshot {
        DiagnosticSnapshot(
            id: id,
            timestamp: timestamp,
            severity: severity.rawValue,
            category: category.rawValue,
            code: code,
            modelID: modelID?.rawValue,
            durationMilliseconds: durationMilliseconds,
            byteCount: byteCount,
            numericValue: numericValue
        )
    }
}
