import SayItCore
import SayItProtocol

extension TriggerSource {
    var speechJobSource: SpeechJobSource {
        switch self {
        case .service:
            .service
        case .clipboard:
            .clipboard
        case .selection:
            .selection
        case .history:
            .history
        case .preview:
            .preview
        case .frontend:
            .frontend
        case .commandLine:
            .commandLine
        case .http:
            .http
        }
    }
}
