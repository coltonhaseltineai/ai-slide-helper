import SwiftUI
import MatcherCore

@MainActor
@Observable
final class AppModel {
    enum Mode { case edit, present }

    static let sample = """
    Welcome and introductions
    Why sleep matters
      Memory consolidation [cues: remember, learning]
      Immune health
    Tips for better sleep
      Keep a consistent schedule
      Avoid screens before bed
    Questions
    """

    var outlineText: String {
        didSet { UserDefaults.standard.set(outlineText, forKey: "outline") }
    }
    var mode: Mode = .edit
    private(set) var matcher = Matcher(items: [])
    private(set) var current = 0
    let listener = SpeechListener()

    /// Words from the current recognition pass that were already given to the matcher.
    private var fedWordCount = 0

    var items: [OutlineItem] { matcher.items }
    var previewItems: [OutlineItem] { parseOutline(outlineText) }

    init() {
        outlineText = UserDefaults.standard.string(forKey: "outline") ?? Self.sample
        listener.onTranscript = { [weak self] text, isFinal in
            self?.handle(text: text, isFinal: isFinal)
        }
    }

    func toggleMode() {
        if mode == .edit {
            matcher = Matcher(items: parseOutline(outlineText))
            current = max(matcher.current, 0)
            listener.contextualStrings = matcher.items.flatMap { [$0.text] + $0.cues }
            mode = .present
        } else {
            listener.stop()
            mode = .edit
        }
    }

    func toggleListening() {
        guard mode == .present else { return }
        if listener.isListening { listener.stop() } else { fedWordCount = 0; listener.start() }
    }

    func select(_ index: Int) {
        matcher.setCurrent(index)
        current = matcher.current
    }

    func step(_ delta: Int) { select(current + delta) }

    /// Speech arrives as a growing transcript; feed only the words that are new and settled.
    private func handle(text: String, isFinal: Bool) {
        let words = text.split(whereSeparator: \.isWhitespace)
        if words.count < fedWordCount { fedWordCount = 0 }  // a new recognition pass started
        // The last word of a partial result can still change, so hold it back.
        let settled = isFinal ? words.count : max(words.count - 1, 0)
        if settled - fedWordCount >= 3 || (isFinal && settled > fedWordCount) {
            let chunk = words[fedWordCount..<settled].joined(separator: " ")
            fedWordCount = settled
            let next = matcher.feed(chunk)
            if next != current { current = next }
        }
        if isFinal { fedWordCount = 0 }
    }
}
