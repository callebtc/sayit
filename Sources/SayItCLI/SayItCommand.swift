import ArgumentParser
import Foundation
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

    @Option(name: .long, help: "Model identifier.")
    var model: String?

    @Option(name: .long, help: "Language identifier.")
    var language: String?

    @Option(name: .long, help: "Playback rate from 0.5 to 2.")
    var rate: Double?

    @Option(name: .long, help: "Native speaking pace.")
    var pace: Double?

    @Flag(
        exclusivity: .exclusive,
        help: "Choose enqueue, interrupt, or replace-all queue behavior."
    )
    var queuePolicy: CLIQueuePolicy = .enqueue

    @Flag(name: .long, help: "Return as soon as the job is accepted.")
    var detach = false

    @Flag(name: .long, help: "Write machine-readable JSON.")
    var json = false

    @Flag(
        name: .long,
        help: "Allow submissions above the long-text confirmation threshold."
    )
    var allowLongText = false

    mutating func run() async throws {
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

        let service = CLIService()
        do {
            let response = try await service.call(
                .submit(
                    SpeechSubmission(
                        text: input,
                        source: .commandLine,
                        modelID: model,
                        voice: voice,
                        language: language,
                        speakingPace: pace,
                        playbackRate: rate,
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
            try await wait(
                for: job.id,
                service: service,
                interruptMonitor: interruptMonitor
            )
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

    private func wait(
        for id: UUID,
        service: CLIService,
        interruptMonitor: InterruptMonitor
    ) async throws {
        var lastState: SpeechJobState?
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
            if job.state == .awaitingConfirmation {
                _ = try? await service.call(.cancelJob(id))
                throw ServiceFailure(
                    code: "job.confirmation_required",
                    message: "Long text requires --allow-long-text."
                )
            }
            if job.state.isTerminal {
                if json {
                    try CLIOutput.json(job)
                }
                switch job.state {
                case .completed:
                    return
                case .canceled:
                    throw CLIExitCode.canceled
                case .failed:
                    if let message = job.errorMessage {
                        CLIOutput.status(message)
                    }
                    throw CLIExitCode.synthesisFailed
                default:
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
