import CoreGraphics
import Foundation

/// Parses the subset of SVG path data used by the app's vector artwork
/// (`M`, `L`, `C`, `Z` in absolute and relative forms) into one `CGPath` per
/// subpath, so individual shapes can be drawn or animated separately.
enum SVGPathParser {
    enum Error: Swift.Error, Equatable {
        case unsupportedCommand(Character)
        case missingCoordinates(Character)
        case missingMoveTo
        case invalidNumber(String)
    }

    static func subpaths(from data: String) throws -> [CGPath] {
        var tokens = Tokens(data)
        var subpaths: [CGPath] = []
        var current: CGMutablePath?
        var point = CGPoint.zero
        var subpathStart = CGPoint.zero
        var command: Character?

        func finishSubpath() {
            if let current, !current.isEmpty {
                subpaths.append(current.copy() ?? current)
            }
            current = nil
        }

        while let token = try tokens.next() {
            switch token {
            case .command(let letter):
                command = letter
                if letter == "Z" || letter == "z" {
                    guard let path = current else { throw Error.missingMoveTo }
                    path.closeSubpath()
                    point = subpathStart
                    finishSubpath()
                    command = nil
                }
                continue
            case .number(let value):
                tokens.pushBack(.number(value))
            }

            guard let letter = command else { throw Error.missingMoveTo }
            let relative = letter.isLowercase
            let origin = relative ? point : .zero

            switch letter {
            case "M", "m":
                let target = try tokens.point(for: letter, offsetBy: origin)
                finishSubpath()
                let path = CGMutablePath()
                path.move(to: target)
                current = path
                point = target
                subpathStart = target
                // Coordinates after a moveto are implicit linetos.
                command = relative ? "l" : "L"
            case "L", "l":
                guard let path = current else { throw Error.missingMoveTo }
                let target = try tokens.point(for: letter, offsetBy: origin)
                path.addLine(to: target)
                point = target
            case "C", "c":
                guard let path = current else { throw Error.missingMoveTo }
                let control1 = try tokens.point(for: letter, offsetBy: origin)
                let control2 = try tokens.point(for: letter, offsetBy: origin)
                let target = try tokens.point(for: letter, offsetBy: origin)
                path.addCurve(to: target, control1: control1, control2: control2)
                point = target
            default:
                throw Error.unsupportedCommand(letter)
            }
        }

        finishSubpath()
        return subpaths
    }
}

private enum Token {
    case command(Character)
    case number(CGFloat)
}

private struct Tokens {
    private let scalars: [Character]
    private var index = 0
    private var pending: Token?

    init(_ data: String) {
        scalars = Array(data)
    }

    mutating func pushBack(_ token: Token) {
        pending = token
    }

    mutating func next() throws -> Token? {
        if let pending {
            self.pending = nil
            return pending
        }
        while index < scalars.count,
              scalars[index].isWhitespace || scalars[index] == "," {
            index += 1
        }
        guard index < scalars.count else { return nil }

        let character = scalars[index]
        if character.isLetter, character != "e", character != "E" {
            index += 1
            return .command(character)
        }

        let start = index
        index += 1
        while index < scalars.count {
            let next = scalars[index]
            let previous = scalars[index - 1]
            if next.isNumber || next == "." && !scalars[start..<index].contains(".") {
                index += 1
            } else if next == "e" || next == "E" {
                index += 1
            } else if (next == "-" || next == "+") && (previous == "e" || previous == "E") {
                index += 1
            } else {
                break
            }
        }
        let text = String(scalars[start..<index])
        guard let value = Double(text) else {
            throw SVGPathParser.Error.invalidNumber(text)
        }
        return .number(CGFloat(value))
    }

    mutating func point(for command: Character, offsetBy origin: CGPoint) throws -> CGPoint {
        guard case .number(let x) = try next(), case .number(let y) = try next() else {
            throw SVGPathParser.Error.missingCoordinates(command)
        }
        return CGPoint(x: origin.x + x, y: origin.y + y)
    }
}
