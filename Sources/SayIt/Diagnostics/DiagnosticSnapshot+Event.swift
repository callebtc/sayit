import SayItCore
import SayItProtocol

extension DiagnosticSnapshot {
    var event: DiagnosticEvent {
        DiagnosticEvent(
            id: id,
            timestamp: timestamp,
            severity: DiagnosticSeverity(rawValue: severity) ?? .error,
            category: DiagnosticCategory(rawValue: category) ?? .lifecycle,
            code: code,
            modelID: modelID.map { ModelID($0) },
            durationMilliseconds: durationMilliseconds,
            byteCount: byteCount,
            numericValue: numericValue
        )
    }
}
