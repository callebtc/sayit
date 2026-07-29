import Foundation
import SayItProtocol

struct IdempotencyEntry: Sendable {
    let expiresAt: Date
    let job: SpeechJob
}
