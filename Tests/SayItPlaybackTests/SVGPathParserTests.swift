import CoreGraphics
import Testing
@testable import SayIt

@Suite("SVG path parser")
struct SVGPathParserTests {
    @Test("Each closed subpath becomes its own path")
    func splitsSubpaths() throws {
        let paths = try SVGPathParser.subpaths(
            from: "M 0,0 L 10,0 L 10,10 Z M 20,20 l 5,0 l 0,5 z"
        )
        #expect(paths.count == 2)
        #expect(paths[0].boundingBoxOfPath == CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(paths[1].boundingBoxOfPath == CGRect(x: 20, y: 20, width: 5, height: 5))
    }

    @Test("Relative curves are offset from the current point")
    func relativeCurves() throws {
        let paths = try SVGPathParser.subpaths(from: "M 10,10 c 0,0 10,0 10,10 Z")
        let bounds = try #require(paths.first).boundingBoxOfPath
        #expect(bounds == CGRect(x: 10, y: 10, width: 10, height: 10))
    }

    @Test("Coordinates after a moveto are implicit linetos")
    func implicitLineTo() throws {
        let paths = try SVGPathParser.subpaths(from: "M0 0 5 0 5 -5e0 Z")
        let bounds = try #require(paths.first).boundingBoxOfPath
        #expect(bounds == CGRect(x: 0, y: -5, width: 5, height: 5))
    }

    @Test("Unsupported commands are rejected")
    func unsupportedCommand() {
        #expect(throws: SVGPathParser.Error.unsupportedCommand("Q")) {
            try SVGPathParser.subpaths(from: "M 0,0 Q 1,1 2,2")
        }
    }

    @Test("Drawing before a moveto is rejected")
    func missingMoveTo() {
        #expect(throws: SVGPathParser.Error.missingMoveTo) {
            try SVGPathParser.subpaths(from: "L 1,1")
        }
    }

    @Test("Incomplete coordinates are rejected")
    func missingCoordinates() {
        #expect(throws: SVGPathParser.Error.missingCoordinates("c")) {
            try SVGPathParser.subpaths(from: "M 0,0 c 1,1 2,2")
        }
    }

    @Test("Malformed numbers are rejected")
    func invalidNumber() {
        #expect(throws: SVGPathParser.Error.invalidNumber("-")) {
            try SVGPathParser.subpaths(from: "M 0,0 L - 2")
        }
    }
}
