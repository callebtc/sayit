import Foundation
import SayItCore

/// Port for obtaining a loaded speech model session. Failed or cancelled
/// loads clean up inside the loader, so callers never hold a partial
/// candidate.
protocol SpeechModelLoading: Sendable {
    func load(
        model: ModelDescriptor,
        directory: URL
    ) async throws -> any SpeechModelSession

    /// Prepare model-family dependencies (text processors) without
    /// loading a model.
    func prepareDependencies(for model: ModelDescriptor) async throws
}
