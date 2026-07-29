import Foundation

extension String {
    func leftPadding(toLength: Int, withPad character: Character) -> String {
        guard count < toLength else { return self }
        return String(repeating: String(character), count: toLength - count) + self
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
