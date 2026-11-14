import Foundation

/// Rewrites English text the way it is read aloud before Woof sees it.
///
/// Woof spells out exactly the characters it receives, so numbers, prices,
/// times and common symbols are expanded into words here. Rules run from the
/// most specific pattern (phone numbers) to the most general (bare digits).
struct WoofTextNormalizer: Sendable {
    private struct Rule: Sendable {
        let expression: NSRegularExpression
        let replacement: @Sendable ([String?]) -> String?
    }

    private static let ones = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
        "sixteen", "seventeen", "eighteen", "nineteen"
    ]
    private static let tens = [
        "", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
        "eighty", "ninety"
    ]
    private static let scales = [
        "", " thousand", " million", " billion", " trillion", " quadrillion", " quintillion"
    ]
    private static let irregularOrdinals = [
        "one": "first", "two": "second", "three": "third", "five": "fifth",
        "eight": "eighth", "nine": "ninth", "twelve": "twelfth"
    ]
    private static let currencies: [String: (unit: String, units: String, minor: String, minors: String)] = [
        "$": ("dollar", "dollars", "cent", "cents"),
        "€": ("euro", "euros", "cent", "cents"),
        "£": ("pound", "pounds", "penny", "pence")
    ]

    private let rules: [Rule]

    init() {
        func rule(
            _ pattern: String,
            _ replacement: @escaping @Sendable ([String?]) -> String?
        ) -> Rule {
            // The patterns are constants covered by tests.
            Rule(
                expression: try! NSRegularExpression(
                    pattern: pattern,
                    options: [.caseInsensitive]
                ),
                replacement: replacement
            )
        }

        let whole = #"(\d{1,3}(?:,\d{3})+|\d+)"#
        rules = [
            // #5
            rule(#"(?<!\w)#(?=\s?\d)"#) { _ in "number " },
            // 415-555-0199, (415) 555 0199, +1 415 555 0199, 1-800-555-0199
            rule(#"(?<![\w-])(?:(\+)?(1)[\s.-])?\(?(\d{3})\)?[\s.-](\d{3})[\s.-](\d{4})(?![\w-])"#) {
                // A dialing prefix of +1 stays silent; a bare leading 1 is spoken.
                Self.phoneNumber([$0[1] == nil ? $0[2] : nil, $0[3], $0[4], $0[5]])
            },
            // 555-0199
            rule(#"(?<![\w.,$€£-])(\d{3})-(\d{4})(?![\w-])"#) {
                Self.phoneNumber([$0[1], $0[2]])
            },
            // -5, +3, -$5, 10 -3.5; not the dash in 10%-15%, or in 10 -20, which reads as a range
            rule(#"(?<![\w.%])(?:\+|(?<!\d[ \t])-|-(?=[$€£]|\d+(?:,\d{3})*(?:\.\d|\s?%)))(?=[$€£]?\d)"#) {
                $0[0] == "-" ? "minus " : "plus "
            },
            // $5.30, €40, £1,250.99, $2.5 million
            rule(#"([$€£])\s?\#(whole)(?:\.(\d+))?(?:\s?(thousand|million|billion|trillion)\b)?"#) {
                Self.money(symbol: $0[1], whole: $0[2], fraction: $0[3], scale: $0[4])
            },
            // 5:30 p.m., 10:05, 12:00. A final period stays only where it ends a sentence.
            rule(#"(?<![\d:])(\d{1,2}):(\d{2})(?![\d:])(?:\s?([ap])\.?\s?m\b(?:(\.)(?=\s*$|\s+(?-i:\p{Lu}))|\.)?)?"#) {
                Self.time(hour: $0[1], minute: $0[2], meridiem: $0[3], period: $0[4])
            },
            // 9am, 5 p.m.
            rule(#"(?<![\d:.])(\d{1,2})\s?([ap])\.?\s?m\b(?:(\.)(?=\s*$|\s+(?-i:\p{Lu}))|\.)?"#) {
                Self.time(hour: $0[1], minute: nil, meridiem: $0[2], period: $0[3])
            },
            // 45%, 3.5 %, 1,250.5%
            rule(#"(?<![\d.,])\#(whole)(?:\.(\d+))?\s?%"#) { groups in
                groups[1].map { Self.quantity($0, fraction: groups[2]) + " percent" }
            },
            // 1st, 22nd, 103rd, 4th
            rule(#"(?<![\d.,])\#(whole)(st|nd|rd|th)\b"#) {
                $0[1].flatMap { Int($0.replacing(",", with: "")) }.map(Self.ordinal)
            },
            // 1990s, 2000s
            rule(#"(?<![\d.])(1\d\d0|20\d0)'?s\b"#) {
                $0[1].flatMap(Int.init).map { Self.plural(Self.year($0)) }
            },
            // 10-20, 3–5, 1990-1995, 3,000-5,000
            rule(#"(?<![\d.,-])\#(whole)\s?-\s?\#(whole)(?!\d|[.,]\d|-)"#) {
                Self.range(from: $0[1], to: $0[2])
            },
            // 2.0.1
            rule(#"(?<![\d.])\d+(?:\.\d+){2,}(?!\d|\.\d)"#) {
                $0[0].map {
                    $0.split(separator: ".").map { Self.number(String($0)) }
                        .joined(separator: " point ")
                }
            },
            // 3.14, 1,234.56
            rule(#"(?<![\d.,])\#(whole)\.(\d+)(?!\d|\.\d)"#) { groups in
                groups[1].map { Self.quantity($0, fraction: groups[2]) }
            },
            // 1066, 1999, 2024: standalone four-digit numbers read as years
            rule(#"(?<![\d.,])(1\d{3}|20\d\d)(?!\d|[.,]\d)"#) {
                $0[1].map(Self.yearOrNumber)
            },
            // 1,000,000 and any remaining digits
            rule(#"\d{1,3}(?:,\d{3})+(?!\d)|\d+"#) {
                $0[0].map { Self.quantity($0, fraction: nil) }
            },
            rule(#"&"#) { _ in " and " },
        ]
    }

    func normalize(_ text: String) -> String {
        var text = text
            .replacing("’", with: "'")
            .replacing("‘", with: "'")
            .replacing("“", with: "\"")
            .replacing("”", with: "\"")
            .replacing("–", with: "-")
            .replacing("−", with: " minus ")
        for rule in rules {
            text = Self.applying(rule, to: text)
        }
        return text
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func applying(_ rule: Rule, to text: String) -> String {
        let source = text as NSString
        var output = ""
        var cursor = 0
        for match in rule.expression.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        ) {
            let groups = (0..<match.numberOfRanges).map { index -> String? in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : source.substring(with: range)
            }
            guard let replacement = rule.replacement(groups) else { continue }
            output += source.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor)
            )
            output += replacement
            cursor = match.range.location + match.range.length
        }
        return output + source.substring(from: cursor)
    }

    static func cardinal(_ value: Int) -> String {
        if value < 0 {
            return "minus " + cardinal(-value)
        }
        if value < 20 {
            return ones[value]
        }
        if value < 100 {
            return tens[value / 10] + (value % 10 == 0 ? "" : " " + ones[value % 10])
        }
        if value < 1_000 {
            let rest = value % 100
            return ones[value / 100] + " hundred" + (rest == 0 ? "" : " " + cardinal(rest))
        }
        var groups: [String] = []
        var remaining = value
        for scale in scales {
            guard remaining > 0 else { break }
            let group = remaining % 1_000
            if group > 0 {
                groups.insert(cardinal(group) + scale, at: 0)
            }
            remaining /= 1_000
        }
        return groups.joined(separator: " ")
    }

    static func ordinal(_ value: Int) -> String {
        var words = cardinal(value).split(separator: " ").map(String.init)
        guard let last = words.popLast() else { return "" }
        let ordinal = if let irregular = irregularOrdinals[last] {
            irregular
        } else if last.hasSuffix("y") {
            String(last.dropLast()) + "ieth"
        } else {
            last + "th"
        }
        return (words + [ordinal]).joined(separator: " ")
    }

    static func year(_ value: Int) -> String {
        guard !(2_000...2_009).contains(value), value % 1_000 != 0 else {
            return cardinal(value)
        }
        let century = value / 100
        let rest = value % 100
        if rest == 0 {
            return cardinal(century) + " hundred"
        }
        return cardinal(century) + (rest < 10 ? " oh " : " ") + cardinal(rest)
    }

    private static func yearOrNumber(_ text: String) -> String {
        Int(text).map(year) ?? number(text)
    }

    static func digits(_ text: String) -> String {
        text.compactMap(\.wholeNumberValue).map { ones[$0] }.joined(separator: " ")
    }

    /// Whole numbers above fifteen digits, or with a leading zero, are read digit by digit.
    static func number(_ text: String) -> String {
        guard text.count <= 15, text.count == 1 || !text.hasPrefix("0"),
              let value = Int(text) else {
            return digits(text)
        }
        return cardinal(value)
    }

    private static func phoneNumber(_ groups: [String?]) -> String {
        groups.compactMap { $0.map(digits) }.joined(separator: ", ")
    }

    /// Four-digit bounds read as years; others as quantities.
    private static func range(from first: String?, to second: String?) -> String? {
        guard let first, let second else { return nil }
        guard first.count == 4, second.count == 4 else {
            return quantity(first, fraction: nil) + " to " + quantity(second, fraction: nil)
        }
        return yearOrNumber(first) + " to " + yearOrNumber(second)
    }

    /// A whole number with optional grouping commas and decimal digits.
    private static func quantity(_ whole: String, fraction: String?) -> String {
        let whole = whole.replacing(",", with: "")
        return fraction.map { decimal(whole + "." + $0) } ?? number(whole)
    }

    static func decimal(_ text: String) -> String {
        let parts = text.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return number(text) }
        return number(parts[0]) + " point " + digits(parts[1])
    }

    private static func plural(_ words: String) -> String {
        words.hasSuffix("y") ? String(words.dropLast()) + "ies" : words + "s"
    }

    private static func money(
        symbol: String?,
        whole: String?,
        fraction: String?,
        scale: String?
    ) -> String? {
        guard let symbol, let names = currencies[symbol], let whole else { return nil }
        let amount = whole.replacing(",", with: "")
        if let scale {
            let value = fraction.map { decimal(amount + "." + $0) } ?? number(amount)
            return "\(value) \(scale.lowercased()) \(names.units)"
        }
        guard let units = Int(amount) else { return nil }
        let minor: Int
        if let fraction {
            guard fraction.count <= 2, let value = Int(fraction) else {
                return decimal(amount + "." + fraction) + " " + names.units
            }
            minor = fraction.count == 1 ? value * 10 : value
        } else {
            minor = 0
        }
        let major = "\(number(amount)) \(units == 1 ? names.unit : names.units)"
        if minor == 0 {
            return major
        }
        let change = "\(cardinal(minor)) \(minor == 1 ? names.minor : names.minors)"
        return units == 0 ? change : "\(major) and \(change)"
    }

    private static func time(
        hour: String?,
        minute: String?,
        meridiem: String?,
        period: String?
    ) -> String? {
        guard let hour = hour.flatMap(Int.init), (0...23).contains(hour) else { return nil }
        let minutes = minute.flatMap(Int.init) ?? 0
        guard (0...59).contains(minutes) else { return nil }
        var words = cardinal(hour)
        if minutes > 0 {
            words += (minutes < 10 ? " oh " : " ") + cardinal(minutes)
        }
        guard let meridiem else {
            return minutes == 0 ? words + " o'clock" : words
        }
        return words + " \(meridiem.uppercased())M" + (period ?? "")
    }
}
