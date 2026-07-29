import Foundation

public enum ServiceResponse: Codable, Sendable {
    case snapshot(ServiceSnapshot)
    case events([ServiceEvent])
    case job(SpeechJob)
    case jobs([SpeechJob])
    case models([ModelSnapshot])
    case history([HistorySnapshot])
    case diagnostics([DiagnosticSnapshot])
    case tokens([APITokenMetadata])
    case createdToken(APITokenCreation)
    case file(ExportedFile)
    case accepted
    case failure(ServiceFailure)
}
