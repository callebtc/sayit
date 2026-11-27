import Foundation
import SayItCore
import Testing

@Suite("Localization catalog")
struct LocalizationTests {
    private static let placeholderRegex = try! NSRegularExpression(
        pattern: #"%(\d+\$)?[+#0\-]*(\d+|\*)?(\.(\d+|\*))?(ll|l|h|hh|z|t|j)?[@dDuUxXoOfeEgGcCsSp]"#
    )

    private struct CatalogDocument: Decodable {
        let sourceLanguage: String
        let strings: [String: StringEntry]
    }

    private struct StringEntry: Decodable {
        let shouldTranslate: Bool?
        let localizations: [String: LocalizationValue]?
    }

    private struct LocalizationValue: Decodable {
        let stringUnit: StringUnit?
    }

    private struct StringUnit: Decodable {
        let state: String
        let value: String
    }

    private var repositoryRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func loadCatalog(named filename: String) throws -> CatalogDocument {
        let url = repositoryRoot
            .appending(path: "Sources/SayIt/Resources")
            .appending(path: filename)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CatalogDocument.self, from: data)
    }

    private func placeholders(in string: String) -> [String] {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return Self.placeholderRegex.matches(in: string, range: range).compactMap { match in
            Range(match.range, in: string).map { String(string[$0]) }
        }.sorted()
    }

    @Test("Every translatable UI string has a translated zh-Hans entry with matching placeholders")
    func localizableCatalogComplete() throws {
        let catalog = try loadCatalog(named: "Localizable.xcstrings")
        #expect(catalog.sourceLanguage == "en")
        #expect(!catalog.strings.isEmpty)

        for (key, entry) in catalog.strings {
            if entry.shouldTranslate == false { continue }

            let zhUnit = try #require(
                entry.localizations?["zh-Hans"]?.stringUnit,
                "Missing zh-Hans localization for key: \(key)"
            )
            #expect(zhUnit.state == "translated", "Untranslated zh-Hans state for key: \(key)")
            #expect(!zhUnit.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty zh-Hans translation for key: \(key)")

            let expectedEnglish = entry.localizations?["en"]?.stringUnit?.value ?? key
            #expect(
                placeholders(in: expectedEnglish) == placeholders(in: zhUnit.value),
                "Format placeholder mismatch for key: \(key)"
            )
        }
    }

    @Test("Every bundled model experience note is localized for zh-Hans")
    func modelExperienceNotesAreLocalized() throws {
        let catalog = try loadCatalog(named: "Localizable.xcstrings")
        let models = try ModelCatalogLoader().bundledCatalog().models
        let notes = Set(models.compactMap { $0.experience?.note })
        #expect(!notes.isEmpty)

        for note in notes {
            let zhUnit = try #require(
                catalog.strings[note]?.localizations?["zh-Hans"]?.stringUnit,
                "Missing zh-Hans localization for model note: \(note)"
            )
            #expect(zhUnit.state == "translated")
            #expect(!zhUnit.value.isEmpty)
        }
    }

    @Test("InfoPlist strings provide zh-Hans localization for microphone usage")
    func infoPlistCatalogComplete() throws {
        let catalog = try loadCatalog(named: "InfoPlist.xcstrings")
        #expect(catalog.sourceLanguage == "en")
        let micUnit = try #require(
            catalog.strings["NSMicrophoneUsageDescription"]?.localizations?["zh-Hans"]?.stringUnit
        )
        #expect(micUnit.state == "translated")
        #expect(!micUnit.value.isEmpty)
    }
}
