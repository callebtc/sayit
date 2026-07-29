import Foundation

import SayItCore

struct HistoryItemSnapshot: Identifiable, Sendable {
    let id: UUID
    let title: String
    let cleanedText: String
    let createdAt: Date
    let modelID: ModelID
    let voice: String?
    let duration: TimeInterval
    let audioRelativePath: String?
    let state: SpeechItemState
    let isPinned: Bool
}
