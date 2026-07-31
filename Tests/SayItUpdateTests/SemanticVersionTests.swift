import Testing

@Suite("Semantic versions")
struct SemanticVersionTests {
    @Test("Parses release tags with an optional V prefix")
    func parsesReleaseTags() throws {
        let lowercase = try #require(SemanticVersion(tag: "v1.2.3"))
        let uppercase = try #require(SemanticVersion(tag: "  V2.0.1  "))

        #expect(lowercase.description == "1.2.3")
        #expect(uppercase.description == "2.0.1")
    }

    @Test("Compares each numeric component")
    func comparesNumericComponents() throws {
        let newerMinor = try #require(SemanticVersion(tag: "1.10.0"))
        let olderMinor = try #require(SemanticVersion(tag: "1.9.9"))
        let newerPatch = try #require(SemanticVersion(tag: "1.10.1"))

        #expect(newerMinor > olderMinor)
        #expect(newerPatch > newerMinor)
    }

    @Test("Uses semantic prerelease precedence")
    func comparesPrereleases() throws {
        let beta2 = try #require(SemanticVersion(tag: "1.0.0-beta.2"))
        let beta11 = try #require(SemanticVersion(tag: "1.0.0-beta.11"))
        let release = try #require(SemanticVersion(tag: "1.0.0"))

        #expect(beta2 < beta11)
        #expect(beta11 < release)
    }

    @Test("Build metadata does not change precedence")
    func ignoresBuildMetadataForPrecedence() throws {
        let first = try #require(SemanticVersion(tag: "1.2.3+build.1"))
        let second = try #require(SemanticVersion(tag: "1.2.3+build.2"))

        #expect(first == second)
        #expect(first.description == "1.2.3+build.1")
    }

    @Test(
        "Rejects malformed tags",
        arguments: [
            "",
            "v",
            "1.2",
            "1.2.3.4",
            "version1.2.3",
            "vv1.2.3",
            "1.02.3",
            "1.2.3-",
            "1.2.3+",
            "1.2.3-01",
            "1.2.3_beta"
        ]
    )
    func rejectsMalformedTags(_ tag: String) {
        #expect(SemanticVersion(tag: tag) == nil)
    }
}
