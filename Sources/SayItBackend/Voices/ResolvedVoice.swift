import Foundation
import SayItCore

struct ResolvedVoice {
    let preset: String?
    let mode: VoiceSynthesisMode
    let reference: VoiceReference?
    let profileID: UUID?
    let profileName: String?
    let tuning: VoiceSynthesisTuning?
}
