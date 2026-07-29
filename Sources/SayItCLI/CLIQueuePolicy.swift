import ArgumentParser
import SayItProtocol

enum CLIQueuePolicy: String, EnumerableFlag {
    case enqueue
    case interrupt
    case replaceAll

    var servicePolicy: QueuePolicy {
        switch self {
        case .enqueue:
            .enqueue
        case .interrupt:
            .interruptCurrent
        case .replaceAll:
            .replaceAll
        }
    }
}
