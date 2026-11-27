import Foundation
import SayItProtocol

extension VoiceTuningParameter {
    var localizedTitle: String {
        switch key {
        case "temperature":
            String(localized: "Temperature")
        case "topP":
            String(localized: "Top P")
        case "topK":
            String(localized: "Top K")
        case "repetitionPenalty":
            String(localized: "Repetition")
        case "cfg":
            String(localized: "CFG")
        case "exaggeration":
            String(localized: "Exaggeration")
        case "diffusionSteps":
            String(localized: "Diffusion Steps")
        case "guidance":
            String(localized: "Guidance")
        case "positionTemperature":
            String(localized: "Position Temperature")
        case "classTemperature":
            String(localized: "Class Temperature")
        case "timeShift":
            String(localized: "Time Shift")
        default:
            title
        }
    }
}
