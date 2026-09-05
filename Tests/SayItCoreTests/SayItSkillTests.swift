import Foundation
import Testing
@testable import SayItCore

@Suite("Say It agent skill")
struct SayItSkillTests {
    @Test("Bundled skill is available at an absolute path")
    func bundledSkillIsAvailable() throws {
        let skillURL = try #require(SayItSkill.bundledURL)

        #expect(skillURL.path.hasPrefix("/"))
        #expect(skillURL.lastPathComponent == "SKILL.md")
        #expect(FileManager.default.fileExists(atPath: skillURL.path))
    }

    @Test("Bundled skill matches the repository skill")
    func bundledSkillMatchesRepositorySkill() throws {
        let bundledURL = try #require(SayItSkill.bundledURL)
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "skills/sayit/SKILL.md")

        #expect(
            try String(contentsOf: bundledURL, encoding: .utf8)
                == String(contentsOf: repositoryURL, encoding: .utf8)
        )
    }
}
