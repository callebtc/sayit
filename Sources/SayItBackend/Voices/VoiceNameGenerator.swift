import Foundation

struct VoiceNameGenerator: Sendable {
    private let adjectives = [
        "Amber", "Bright", "Calm", "Clear", "Cobalt", "Gentle",
        "Golden", "Lunar", "Mellow", "Quiet", "Silver", "Velvet"
    ]
    private let nouns = [
        "Brook", "Cedar", "Finch", "Harbor", "Lark", "Meadow",
        "Orchid", "Reed", "Robin", "Sparrow", "Willow", "Wren"
    ]

    func name(excluding existingNames: Set<String>) -> String {
        let normalized = Set(existingNames.map { $0.lowercased() })
        for _ in 0..<adjectives.count * nouns.count {
            let candidate = "\(adjectives.randomElement() ?? "Quiet") \(nouns.randomElement() ?? "Wren")"
            if !normalized.contains(candidate.lowercased()) {
                return candidate
            }
        }
        var suffix = 2
        while normalized.contains("quiet wren \(suffix)") {
            suffix += 1
        }
        return "Quiet Wren \(suffix)"
    }
}
