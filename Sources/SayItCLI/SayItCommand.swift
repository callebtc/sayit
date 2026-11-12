import ArgumentParser
import Foundation
import SayItCore
import SayItProtocol

struct SpeakCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speak",
        abstract: "Read text aloud using the Say It background service."
    )

    @Argument(help: "Text to read. Reads UTF-8 from stdin when omitted.")
    var text: [String] = []

    @Option(name: .long, help: "Voice identifier.")
    var voice: String?

    @Option(
        name: .long,
        help: "Saved voice profile UUID or exact name."
    )
    var voiceProfile: String?

    @Flag(
        name: .long,
        help: "Generate a fresh random voice for every paragraph."
    )
    var randomVoicePerParagraph = false

    @Option(name: .long, help: "Model identifier.")
    var model: String?

    @Option(name: .long, help: "Language identifier.")
    var language: String?

    @Option(
        name: .long,
        help: "Playback speed only (\(PlaybackRate.minimum)–\(PlaybackRate.maximum)); does not change saved audio."
    )
    var rate: Double?

    @Option(name: .long, help: "Native speaking pace on supported models; included in saved audio.")
    var pace: Double?

    @Option(name: [.short, .long], help: "Save generated speech to a new .wav file.")
    var output: String?

    @Option(
        name: .long,
        help: "Speed multiplier baked into the WAV only (\(PlaybackRate.minimum)–\(PlaybackRate.maximum); default 1)."
    )
    var exportRate: Double?

    @Flag(name: .long, help: "Generate without playback. Requires --output.")
    var noPlay = false

    @Flag(
        exclusivity: .exclusive,
        help: "Choose enqueue, interrupt, or replace-all queue behavior."
    )
    var queuePolicy: CLIQueuePolicy = .interrupt

    @Flag(name: .long, help: "Return as soon as the job is accepted.")
    var detach = false

    @Flag(name: .long, help: "Write machine-readable JSON.")
    var json = false

    @Flag(
        name: .long,
        help: "Allow submissions above the long-text confirmation threshold."
    )
    var allowLongText = false

    mutating func validate() throws {
        if let exportRate, !PlaybackRate.isSupported(exportRate) {
            throw ValidationError(
                "Choose an --export-rate from \(PlaybackRate.minimum) to \(PlaybackRate.maximum)."
            )
        }
        if output == nil, exportRate != nil || noPlay {
            throw ValidationError("--export-rate and --no-play require --output.")
        }
        if output != nil, detach {
            throw ValidationError("--output cannot be combined with --detach; saving waits for generation.")
        }
        if let output {
            _ = try CLIExportDestination(path: output)
        }
    }

    mutating func run() async throws {
        let destination = try output.map { try CLIExportDestination(path: $0) }
        let input = text.isEmpty
            ? String(
                decoding: FileHandle.standardInput.readDataToEndOfFile(),
                as: UTF8.self
            )
            : text.joined(separator: " ")
        guard !input.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw ValidationError("Provide text as arguments or on stdin.")
        }
        let selectionCount = [
            voice != nil,
            voiceProfile != nil,
            randomVoicePerParagraph
        ].count(where: { $0 })
        guard selectionCount <= 1 else {
            throw ValidationError(
                "Use only one of --voice, --voice-profile, or --random-voice-per-paragraph."
            )
        }

        let service = CLIService()
        do {
            let resolved = try await resolvedVoice(using: service)
            let response = try await service.call(
                .submit(
                    SpeechSubmission(
                        text: input,
                        source: .commandLine,
                        modelID: resolved.modelID ?? model,
                        voice: voice,
                        voiceSelection: resolved.selection,
                        language: language,
                        speakingPace: pace,
                        playbackRate: rate,
                        playbackEnabled: noPlay ? false : nil,
                        queuePolicy: queuePolicy.servicePolicy,
                        permitsLongText: allowLongText
                    )
                )
            )
            guard case .job(let job) = response else {
                throw ServiceFailure(
                    code: "job.invalid_response",
                    message: "The service did not return a speech job."
                )
            }

            if detach {
                if json {
                    try CLIOutput.json(job)
                } else {
                    CLIOutput.standard(job.id.uuidString)
                }
                return
            }
            let interruptMonitor = InterruptMonitor()
            let completedJob = try await wait(
                for: job.id,
                service: service,
                interruptMonitor: interruptMonitor
            )
            if let destination {
                let response = try await service.call(
                    .exportHistory(job.id, format: "wav", rate: exportRate ?? 1)
                )
                guard case .file(let file) = response else {
                    throw ServiceFailure(
                        code: "export.invalid_response",
                        message: "The service did not return generated audio."
                    )
                }
                if await interruptMonitor.consume() {
                    throw CLIExitCode.canceled
                }
                do {
                    try destination.write(file.data)
                } catch {
                    CLIOutput.status("Could not save WAV: \(error.localizedDescription)")
                    throw CLIExitCode.outputFailed
                }
                if !json {
                    CLIOutput.status("Saved \(destination.url.path)")
                }
            }
            if json {
                try CLIOutput.json(completedJob)
            }
        } catch let code as ExitCode {
            throw code
        } catch let failure as ServiceFailure {
            CLIOutput.status(failure.message)
            throw CLIExitCode.rejected
        } catch {
            CLIOutput.status("Say It background service is unavailable.")
            throw CLIExitCode.unavailable
        }
    }

    private func resolvedVoice(
        using service: CLIService
    ) async throws -> (selection: VoiceSelection?, modelID: String?) {
        if randomVoicePerParagraph {
            return (.randomPerParagraph, nil)
        }
        guard let voiceProfile else {
            return (nil, nil)
        }
        let response = try await service.call(.voices(modelID: nil))
        guard case .voices(let profiles) = response else {
            throw ServiceFailure(
                code: "voice.invalid_response",
                message: "The service did not return saved voices."
            )
        }
        let snapshotResponse = try await service.call(.snapshot)
        guard case .snapshot(let snapshot) = snapshotResponse else {
            throw ServiceFailure(
                code: "voice.invalid_response",
                message: "The service did not return its active model."
            )
        }
        let profile = try VoiceProfileResolver().resolve(
            identifier: voiceProfile,
            requestedModelID: model,
            currentModelID: snapshot.settings.activeModelID,
            profiles: profiles
        )
        return (.profile(profile.id), profile.modelID)
    }

    private func wait(
        for id: UUID,
        service: CLIService,
        interruptMonitor: InterruptMonitor
    ) async throws -> SpeechJob {
        var lastState: SpeechJobState?
        var lastQueueBlock: QueueBlockReason?
        while true {
            if await interruptMonitor.consume() {
                _ = try? await service.call(.cancelJob(id))
                CLIOutput.status("canceled")
                throw CLIExitCode.canceled
            }
            let response = try await service.call(.jobs)
            guard case .jobs(let jobs) = response,
                  let job = jobs.first(where: { $0.id == id }) else {
                throw ServiceFailure(
                    code: "job.not_found",
                    message: "The submitted speech job is no longer available."
                )
            }
            if lastState != job.state, !json {
                CLIOutput.status(job.state.rawValue)
                lastState = job.state
            }
            if job.state == .queued, !json {
                let snapshotResponse = try await service.call(.snapshot)
                if case .snapshot(let snapshot) = snapshotResponse,
                   let queueBlock = snapshot.queueBlock,
                   queueBlock.reason != lastQueueBlock {
                    CLIOutput.status(queueBlock.message)
                    lastQueueBlock = queueBlock.reason
                }
            } else {
                lastQueueBlock = nil
            }
            if job.state == .awaitingConfirmation {
                _ = try? await service.call(.cancelJob(id))
                throw ServiceFailure(
                    code: "job.confirmation_required",
                    message: "Long text requires --allow-long-text."
                )
            }
            if job.state.isTerminal {
                if json, job.state != .completed {
                    try CLIOutput.json(job)
                }
                switch job.state {
                case .completed:
                    return job
                case .canceled:
                    throw CLIExitCode.canceled
                case .failed:
                    if let message = job.errorMessage {
                        CLIOutput.status(message)
                    }
                    throw CLIExitCode.synthesisFailed
                default:
                    return job
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
