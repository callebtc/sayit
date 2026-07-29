import SayItCore
import SayItProtocol

extension SpeechJobSource {
    var triggerSource: TriggerSource {
        switch self {
        case .frontend:
            .frontend
        case .commandLine:
            .commandLine
        case .http:
            .http
        case .service:
            .service
        case .clipboard:
            .clipboard
        case .history:
            .history
        case .preview:
            .preview
        }
    }
}
