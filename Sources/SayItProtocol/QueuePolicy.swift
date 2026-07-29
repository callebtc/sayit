import Foundation

public enum QueuePolicy: String, Codable, CaseIterable, Sendable {
    case enqueue
    case interruptCurrent
    case replaceAll
}
