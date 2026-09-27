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

    // Smart following (Claude)
    var aiEnabled: Bool {
        didSet { UserDefaults.standard.set(aiEnabled, forKey: "aiEnabled"); aiDisabledReason = nil }
    }
    var accessCode: String {
        didSet { UserDefaults.standard.set(accessCode, forKey: "accessCode"); aiDisabledReason = nil }
    }
    var aiDisabledReason: String?
    private(set) var library: LearnedLibrary
    private(set) var learnedPulse = 0
    /// Words just learned for a point, shown briefly beside it while presenting.
    private(set) var learnedFlash: LearnedFlash?

    struct LearnedFlash: Equatable {
        let id = UUID()
        let index: Int
        let words: [String]
    }

    /// Words from the current recognition pass that were already given to the matcher.
    private var fedWordCount = 0
    private var chunks: [(time: Date, text: String)] = []
    private var lastCallAt = Date.distantPast
    private var lastConfidentAt = Date()
    private var newWords = 0
    private var locateTask: Task<Void, Never>?
    private var teachTask: Task<Void, Never>?
    private var expandTask: Task<Void, Never>?
    private var lastTeachAt = Date.distantPast
    private var ticker: Timer?

    var items: [OutlineItem] { matcher.items }
    var previewItems: [OutlineItem] { parseOutline(outlineText) }
    var learnedCount: Int { library.learnedCount }
    private var aiOn: Bool { aiEnabled && aiDisabledReason == nil }
    private var client: SmartClient { SmartClient(accessCode: accessCode) }

    init() {
        let defaults = UserDefaults.standard
        outlineText = defaults.string(forKey: "outline") ?? Self.sample
        aiEnabled = defaults.object(forKey: "aiEnabled") as? Bool ?? true
        accessCode = defaults.string(forKey: "accessCode") ?? ""
        if let data = defaults.data(forKey: "library"),
           let saved = try? JSONDecoder().decode(LearnedLibrary.self, from: data) {
            library = saved
        } else {
            library = LearnedLibrary()
        }
        listener.onTranscript = { [weak self] text, isFinal in
            self?.handle(text: text, isFinal: isFinal)
        }
    }

    func toggleMode() {
        if mode == .edit {
            matcher = Matcher(items: parseOutline(outlineText))
            current = max(matcher.current, 0)
            listener.contextualStrings = matcher.items.flatMap { [$0.text] + $0.cues }
            chunks = []
            lastCallAt = Date()
            lastConfidentAt = Date()
            newWords = 0
            locateTask?.cancel()
            loadLibrary()
            mode = .present
        } else {
            stopListening()
            mode = .edit
        }
    }

    func toggleListening() {
        guard mode == .present else { return }
        if listener.isListening {
            stopListening()
        } else {
            fedWordCount = 0
            listener.start()
            // "Unsure for a while" can happen between words, so check on a timer too.
            ticker = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.maybeLocate() }
            }
        }
    }

    private func stopListening() {
        listener.stop()
        ticker?.invalidate()
        ticker = nil
    }

    /// Moves the highlight by hand; Claude learns from the correction.
    func select(_ index: Int) {
        let before = matcher.current
        matcher.setCurrent(index)
        current = matcher.current
        guard current != before else { return }
        lastConfidentAt = Date()
        teachSoon()
    }

    func step(_ delta: Int) { select(current + delta) }

    // MARK: - Tutorial

    struct TutorialPresentation: Identifiable {
        let id = UUID()
        let pages: [TutorialPage]
        let whatsNew: Bool
    }

    var tutorial: TutorialPresentation?

    /// On launch: the full tour for new users, or just the pages for features added since last time.
    func showTutorialIfNeeded() {
        let lastSeen = UserDefaults.standard.integer(forKey: "tutorialSeen")
        let pages = Tutorial.pagesToShow(lastSeen: lastSeen)
        guard !pages.isEmpty else { return }
        tutorial = TutorialPresentation(pages: pages, whatsNew: lastSeen != 0)
    }

    func showFullTutorial() {
        tutorial = TutorialPresentation(pages: Tutorial.pages, whatsNew: false)
    }

    func finishTutorial() {
        let seen = UserDefaults.standard.integer(forKey: "tutorialSeen")
        UserDefaults.standard.set(max(seen, Tutorial.newest), forKey: "tutorialSeen")
        tutorial = nil
    }

    /// Learned words for an outline line, newest first.
    func learnedWords(for text: String) -> [String] { library.learnedWords(text) }

    func removeLearned(_ word: String, for text: String) {
        library.removeLearned(text, word)
        saveLibrary()
    }

    /// Lets you teach a word yourself. Takes effect the next time you present.
    func addLearned(_ word: String, for text: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !w.isEmpty else { return }
        library.addLearned(text, [w])
        saveLibrary()
    }

    func resetLibrary() {
        library = LearnedLibrary()
        saveLibrary()
    }

    /// Speech arrives as a growing transcript; feed only the words that are new and settled.
    private func handle(text: String, isFinal: Bool) {
        let words = text.split(whereSeparator: \.isWhitespace)
        if words.count < fedWordCount { fedWordCount = 0 }  // a new recognition pass started
        // The last word of a partial result can still change, so hold it back.
        let settled = isFinal ? words.count : max(words.count - 1, 0)
        if settled - fedWordCount >= 3 || (isFinal && settled > fedWordCount) {
            let chunk = words[fedWordCount..<settled].joined(separator: " ")
            fedWordCount = settled
            feed(chunk)
        }
        if isFinal { fedWordCount = 0 }
    }

    private func feed(_ chunk: String) {
        let now = Date()
        chunks.append((now, chunk))
        chunks.removeAll { now.timeIntervalSince($0.time) > 60 }
        newWords += chunk.split(whereSeparator: \.isWhitespace).count
        let before = current
        current = matcher.feed(chunk)
        if current != before || matcher.hits(current, chunk) > 0 { lastConfidentAt = now }
        maybeLocate()
    }

    private func recentTranscript(_ seconds: TimeInterval = 25) -> String {
        let now = Date()
        return chunks.filter { now.timeIntervalSince($0.time) < seconds }.map(\.text).joined(separator: " ")
    }

    // MARK: - Claude

    /// Puts saved hint and learned words onto the outline, then fetches hints for any new lines.
    private func loadLibrary() {
        for (i, item) in matcher.items.enumerated() {
            let w = library.words(item.text)
            matcher.addKeywords(i, w.hints, source: .hint)
            matcher.addKeywords(i, w.learned, source: .learned)
        }
        let items = matcher.items
        guard aiOn, !items.isEmpty, !items.allSatisfy({ library.has($0.text) }) else { return }
        let m = matcher
        expandTask?.cancel()
        expandTask = Task {
            do {
                let result = try await client.expand(items: items.map(\.text))
                for (i, words) in result.hints.enumerated() where i < items.count {
                    guard !words.isEmpty, !library.has(items[i].text) else { continue }
                    library.setHints(items[i].text, words)
                    m.addKeywords(i, words, source: .hint)
                }
                saveLibrary()
            } catch {
                aiFailed(error)
            }
        }
    }

    private func maybeLocate() {
        guard mode == .present, aiOn else { return }
        let now = Date().timeIntervalSince1970
        guard shouldLocate(now: now, lastCallAt: lastCallAt.timeIntervalSince1970,
                           lastConfidentAt: lastConfidentAt.timeIntervalSince1970,
                           newWords: newWords, inFlight: locateTask != nil) else { return }
        let transcript = recentTranscript()
        guard !transcript.isEmpty else { return }
        lastCallAt = Date()
        newWords = 0
        let m = matcher, asked = current, texts = matcher.items.map(\.text)
        locateTask = Task {
            defer { locateTask = nil }
            do {
                let r = try await client.locate(items: texts, current: asked, transcript: transcript)
                guard m === matcher, texts.indices.contains(r.index) else { return }
                // Don't override a correction the user made while Claude was thinking.
                if r.confidence == "high", r.index != current, current == asked {
                    matcher.setCurrent(r.index)
                    current = r.index
                }
                if r.confidence == "high" || (r.confidence == "medium" && r.index == current) {
                    learn(r.index, r.learned)
                    lastConfidentAt = Date()
                }
            } catch {
                aiFailed(error)
            }
        }
    }

    /// Waits for taps to settle, then teaches Claude's pick of words for the chosen point.
    private func teachSoon() {
        teachTask?.cancel()
        teachTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await teach(current)
        }
    }

    private func teach(_ index: Int) async {
        guard aiOn, Date().timeIntervalSince(lastTeachAt) > 4 else { return }
        let transcript = recentTranscript(15)
        guard transcript.split(whereSeparator: \.isWhitespace).count >= 6 else { return }
        lastTeachAt = Date()
        let m = matcher
        do {
            let r = try await client.locate(items: m.items.map(\.text), current: index, transcript: transcript, known: index)
            if m === matcher { learn(index, r.learned) }
        } catch {
            aiFailed(error)
        }
    }

    private func learn(_ index: Int, _ words: [String]) {
        guard !words.isEmpty, matcher.items.indices.contains(index) else { return }
        matcher.addKeywords(index, words, source: .learned)
        let text = matcher.items[index].text
        let known = Set(library.learnedWords(text))
        let fresh = Array(Set(words.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }))
            .filter { !$0.isEmpty && !known.contains($0) }.sorted()
        guard library.addLearned(text, words) > 0 else { return }
        saveLibrary()
        learnedPulse += 1
        let flash = LearnedFlash(index: index, words: fresh)
        learnedFlash = flash
        Task {
            try? await Task.sleep(for: .seconds(4))
            if learnedFlash == flash { learnedFlash = nil }
        }
    }

    private func saveLibrary() {
        if let data = try? JSONEncoder().encode(library) {
            UserDefaults.standard.set(data, forKey: "library")
        }
    }

    /// Stops calling Claude for this session after a setup problem, and says why once.
    private func aiFailed(_ error: Error) {
        if error is CancellationError { return }
        if let e = error as? SmartClient.APIError, e.isSetupProblem {
            aiDisabledReason = e.status == 404 ? "Smart following isn't available on the server yet." : e.message
        }
    }
}
