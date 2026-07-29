import Foundation

public struct HardwareAdvisor: Sendable {
    public init() {}

    public func suitability(
        for model: ModelDescriptor,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> ModelSuitability {
        let estimated = UInt64(clamping: model.estimatedPeakMemoryBytes)
        if estimated > physicalMemory * 7 / 10 {
            return .notRecommended
        }
        if estimated > physicalMemory * 4 / 10 || model.hardwareTier == .high {
            return .mayBeSlow
        }
        return .recommended
    }

    public func requiresMemoryConfirmation(
        for model: ModelDescriptor,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Bool {
        UInt64(clamping: model.estimatedPeakMemoryBytes) > physicalMemory * 7 / 10
    }
}
