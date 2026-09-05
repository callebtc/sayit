import AppKit
import Foundation
import SayItProtocol
import SwiftUI

@main
struct LongTextProbe {
    // Only the optional instrumented reader build writes these counters.
    nonisolated(unsafe) static var wordViews = 0
    nonisolated(unsafe) static var measuredWords = 0
    nonisolated(unsafe) static var tokenRebuilds = 0
    nonisolated(unsafe) static var followRequests = 0
    nonisolated(unsafe) static var visibleWords: Set<Int> = []
    nonisolated(unsafe) static var scrollOffset: Double = 0
    nonisolated(unsafe) static var activeWordID = -1
    nonisolated(unsafe) static var activeWordFrame = CGRect.zero
    @MainActor
    static func main() {
        setbuf(stdout, nil)
        let mode = CommandLine.arguments.dropFirst().first ?? "structure"
        let count = Int(CommandLine.arguments.dropFirst(2).first ?? "10000")!
        switch mode {
        case "structure":
            let text = String(repeating: "one two three four five. ", count: count / 5)
            let start = ContinuousClock.now
            let document = try! SpeechReaderDocument.build(text)
            print("words=\(document.tokens.count) blocks=\(document.blocks.count) largestBlock=\(document.blocks.map { $0.words.count }.max() ?? 0) tokenize=\(start.duration(to: .now))")
        case "timing":
            let document = try! SpeechReaderDocument.build(String(repeating: "one two three four five. ", count: 100))
            let chunks = [PlaybackTextChunk(textStart: 0, textEnd: 650, audioStart: 0)]
            for duration in [2.0, 10.0, 40.0] {
                let selected = SpeechLyricsTimeline.wordIndex(at: 1.5, document: document, chunks: chunks, generatedDuration: duration)
                print("generated=\(duration)s selectedWord=\(selected ?? -1) stableMidpoint=\(SpeechLyricsTimeline.timing(forOffset: 325, chunks: chunks))")
            }
        case "chunker":
            let shape = CommandLine.arguments.dropFirst(3).first ?? "paragraphs"
            let text = shape == "paragraphs"
                ? String(repeating: "Café 👋 reads a short sentence.\n", count: count)
                : String(repeating: "café 👋 ", count: count)
            let start = ContinuousClock.now
            let chunks = TextChunker().chunks(for: text)
            print("shape=\(shape) count=\(count) chars=\(text.count) chunks=\(chunks.count) elapsed=\(start.duration(to: .now))")
        case "render", "render-updates", "render-words":
            _ = NSApplication.shared
            let text = String(repeating: "one two three four five. ", count: count / 5)
            let start = ContinuousClock.now
            let screenshot = ProcessInfo.processInfo.environment["SAYIT_PROBE_SCREENSHOT"]
            let initialChunks = screenshot == nil ? [] : [PlaybackTextChunk(
                textStart: 0, textEnd: min(120, text.count), audioStart: 0, audioEnd: 100
            )]
            let host = NSHostingView(rootView: SpeechLyricsView(
                text: text, chunks: initialChunks, elapsed: 1, generatedDuration: 100,
                showsHighlight: screenshot != nil
            ).frame(width: 340, height: 150).background(Color.white).environment(\.colorScheme, .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 150), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            if screenshot != nil {
                window.backgroundColor = .windowBackgroundColor
                window.orderFront(nil)
            }
            host.layoutSubtreeIfNeeded()
            // Wait for asynchronous tokenization to publish, then include layout.
            let deadline = Date(timeIntervalSinceNow: 20)
            while tokenRebuilds == 0, Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            host.layoutSubtreeIfNeeded()
            print("render words=\(count) elapsed=\(start.duration(to: .now)) height=\(host.fittingSize.height) wordViews=\(wordViews) measuredWords=\(measuredWords) tokenRebuilds=\(tokenRebuilds)")
            if count >= 10_000 {
                precondition(wordViews < 2_000, "Offscreen word views grew with document length")
                precondition(measuredWords < 2_000, "Offscreen layout grew with document length")
                precondition(tokenRebuilds == 1, "Reader did not publish one tokenization")
            }
            if mode == "render-updates" {
                let originalBuilds = tokenRebuilds
                for index in 0..<20 {
                    let anchors = (0...index).map { anchor in
                        PlaybackTextChunk(
                            textStart: anchor * 120, textEnd: (anchor + 1) * 120,
                            audioStart: Double(anchor) * 10
                        )
                    }
                    host.rootView = SpeechLyricsView(
                        text: text, chunks: anchors, elapsed: Double(index) * 10,
                        generatedDuration: Double(index + 1) * 10, showsHighlight: true
                    ).frame(width: 340, height: 150).background(Color.white).environment(\.colorScheme, .light)
                    host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
                }
                precondition(tokenRebuilds == originalBuilds, "Audio changes retokenized the document")
                precondition(followRequests >= 20, "Automatic scrolling disabled following")
                print("20 streaming/seek updates tokenRebuilds=\(tokenRebuilds) followRequests=\(followRequests)")
            }
            if mode == "render-words" {
                let document = try! SpeechReaderDocument.build(text)
                let end = document.tokens.last!.sourceRange.upperBound
                let anchors = [PlaybackTextChunk(textStart: 0, textEnd: end, audioStart: 0, audioEnd: Double(end))]
                // Exercise line and block crossings, distant forward/backward seeks,
                // and the final word, using actual production view geometry.
                let targets = Array(0..<96) + [count - 100, 21, count - 1, 0, 75]
                for target in targets {
                    let time = Double(document.tokens[target].sourceRange.lowerBound) + 0.1
                    host.rootView = SpeechLyricsView(
                        text: text, chunks: anchors, elapsed: time,
                        generatedDuration: Double(end), showsHighlight: true
                    ).frame(width: 340, height: 150).background(Color.white).environment(\.colorScheme, .light)
                    host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                    host.layoutSubtreeIfNeeded()
                    let visible = activeWordID == target && activeWordFrame.minY >= 15 && activeWordFrame.maxY <= 135
                    if !visible {
                        print("calculated=\(SpeechLyricsTimeline.wordIndex(at: time, document: document, chunks: anchors, generatedDuration: Double(end)) ?? -1)")
                        print("miss target=\(target) measured=\(activeWordID) frame=\(activeWordFrame) offset=\(scrollOffset)")
                    }
                    precondition(visible, "Active word did not enter the unfaded viewport")
                }
                precondition(tokenRebuilds == 1, "Word updates retokenized the document")
                print("word follow targets=\(targets.count) all visible; tokenRebuilds=\(tokenRebuilds) measuredWords=\(measuredWords)")
            }
            if screenshot != nil || mode == "render-updates" {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
                host.layoutSubtreeIfNeeded()
            }
            if mode == "render-updates" {
                let expected = try! SpeechReaderDocument.build(text).wordIndex(atOrAfter: 19 * 120)!
                print("follow target=\(expected) visible=\(visibleWords.min() ?? -1)...\(visibleWords.max() ?? -1) offset=\(scrollOffset)")
                precondition(visibleWords.contains(expected), "Follow target did not enter the viewport")
            }
            if let screenshot, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try! data.write(to: URL(fileURLWithPath: screenshot))
                }
            }
            window.orderOut(nil)
            window.contentView = nil
        default:
            fatalError("Unknown probe mode")
        }
    }
}
