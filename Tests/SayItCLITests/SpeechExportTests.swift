import ArgumentParser
import Foundation
import Testing
@testable import SayItCLI

struct SpeechExportTests {
    @Test("Export options parse for explicit and default speech commands")
    func exportOptions() throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).wav").path
        for prefix in [[], ["speak"]] {
            let command = try #require(try SayItCommand.parseAsRoot(
                prefix + ["Hello", "-o", path, "--export-rate", "1.2", "--no-play", "--json"]
            ) as? SpeakCommand)
            #expect(command.output == path)
            #expect(command.exportRate == 1.2)
            #expect(command.noPlay)
            #expect(command.json)
            #expect(command.rate == nil)
            #expect(command.pace == nil)
        }
    }

    @Test("Invalid exports are rejected before submitting speech")
    func invalidOptions() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appending(path: "speech.wav").path
        let cases = [
            ["--export-rate", "1.2"],
            ["--no-play"],
            ["--output", output, "--detach"],
            ["--output", ""],
            ["--output", root.appending(path: "speech.mp3").path],
            ["--output", root.appending(path: "missing/speech.wav").path]
        ] + ["nan", "inf", "0", "-1", "99"].map {
            ["--output", output, "--export-rate", $0]
        }
        for arguments in cases {
            #expect(throws: (any Error).self) {
                _ = try SayItCommand.parseAsRoot(["speak", "Hello"] + arguments)
            }
        }
        try Data([1]).write(to: URL(fileURLWithPath: output))
        #expect(throws: (any Error).self) {
            _ = try SayItCommand.parseAsRoot(["Hello", "--output", output])
        }
    }

    @Test("Saving uses the requested path and never replaces an existing file")
    func safeDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "speech.wav")
        let destination = try CLIExportDestination(path: url.path)
        let data = Data([1, 2, 3])
        try destination.write(data)
        #expect(try Data(contentsOf: url) == data)
        #expect(throws: (any Error).self) {
            try destination.write(Data([4]))
        }
        #expect(try Data(contentsOf: url) == data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["speech.wav"])
    }
}
