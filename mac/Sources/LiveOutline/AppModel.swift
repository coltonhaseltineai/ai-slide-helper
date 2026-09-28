import AppKit
import SwiftUI
import MatcherCore

@MainActor
@Observable
final class AppModel {
    enum Mode { case edit, present }

    /// The "Follow by meaning" setting.
    enum FollowMode: String, CaseIterable, Identifiable {
        case automatic, onDevice, tiny, claude, keywords
        var id: String { rawValue }

        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .onDevice: return "Apple on-device model"
            case .tiny: return "Tiny meaning model"
            case .claude: return "Claude"
            case .keywords: return "Keywords only"
            }
        }

        var detail: String {
            switch self {
            case .automatic: return "Free and private: Apple's on-device model when this Mac has it, otherwise the tiny meaning model."
            case .onDevice: return "Apple Intelligence, on this Mac. Free, private, works offline. Needs macOS 26 and Apple silicon."
            case .tiny: return "A small meaning model that runs on any Mac in milliseconds. Downloads once (about 15 MB)."
            case .claude: return "Sends the last few seconds of speech to Claude. Needs an access code and internet."
            case .keywords: return "Only moves when you say the outline's own words (or its [cues:])."
            }
        }
    }

    /// What is following the speaker right now.
    enum Engine: String, Codable {
        case onDevice, tiny, claude, keywords

        var label: String {
            switch self {
            case .onDevice: return "On your Mac"
            case .tiny: return "Tiny model"
            case .claude: return "Claude"
            case .keywords: return "Keywords"
            }
        }

        var symbol: String {
            switch self {
            case .onDevice: return "cpu"
            case .tiny: return "sparkles"
            case .claude: return "cloud"
            case .keywords: return "text.magnifyingglass"
            }
        }
    }

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
    var followMode: FollowMode {
        didSet {
            UserDefaults.standard.set(followMode.rawValue, forKey: "followMode")
            if mode == .present { startEngine() }
        }
    }
    var accessCode: String {
        didSet { UserDefaults.standard.set(accessCode, forKey: "accessCode") }
    }

    var mode: Mode = .edit
    private(set) var matcher = Matcher(items: [])
    private(set) var current = 0
    let listener = SpeechListener()

    /// Who is following right now, and why it isn't what the setting asked for (if it isn't).
    private(set) var engine: Engine = .keywords
    private(set) var engineNote: String?
    /// True while a judge is thinking (the status label pulses).
    private(set) var isJudging = false
    private(set) var stats = SessionStats(engine: "keywords")
    private(set) var lastStats: SessionStats?

    // Live state for the current presentation.
    @ObservationIgnored private var follower = Follower(count: 0)
    @ObservationIgnored private var judge: (any Judge)?
    @ObservationIgnored private var cadence = JudgeCadence.onDevice
    @ObservationIgnored private var tiny: TinyFollower?
    @ObservationIgnored private var tinyChain: Task<Void, Never>?
    @ObservationIgnored private var lastTinyVerdict: JudgeVerdict?
    @ObservationIgnored private var prep: [PointPrep]?
    @ObservationIgnored private var prepCache: [String: [PointPrep]] = [:]   // in memory only, from the outline
    @ObservationIgnored private var session = UUID()
    @ObservationIgnored private var clockStart = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var chunks: [TimedChunk] = []
    @ObservationIgnored private var fedWordCount = 0
    @ObservationIgnored private var lastAskAt = -1e9
    @ObservationIgnored private var lastWordAt = 0.0
    @ObservationIgnored private var newWords = 0
    @ObservationIgnored private var seq = 0
    @ObservationIgnored private var tinySeq = 0
    @ObservationIgnored private var judgeInFlight = false
    @ObservationIgnored private var lastRecheckAt = 0.0
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var activity: NSObjectProtocol?

    var items: [OutlineItem] { matcher.items }
    var previewItems: [OutlineItem] { parseOutline(outlineText) }

    init() {
        let defaults = UserDefaults.standard
        outlineText = defaults.string(forKey: "outline") ?? Self.sample
        accessCode = defaults.string(forKey: "accessCode") ?? ""
        followMode = defaults.string(forKey: "followMode").flatMap(FollowMode.init(rawValue:)) ?? .automatic
        // Live Outline no longer learns words; forget anything older versions saved.
        defaults.removeObject(forKey: "library")
        defaults.removeObject(forKey: "aiEnabled")
        if let data = defaults.data(forKey: "lastSession") { lastStats = try? JSONDecoder().decode(SessionStats.self, from: data) }
        listener.onTranscript = { [weak self] text, isFinal in
            self?.handle(text: text, isFinal: isFinal)
        }
    }

    // MARK: - Presenting

    func toggleMode() {
        if mode == .edit {
            matcher = Matcher(items: parseOutline(outlineText))
            follower = Follower(count: matcher.items.count, policy: .live, current: max(matcher.current, 0))
            current = follower.current
            listener.contextualStrings = matcher.items.flatMap { [$0.text] + $0.cues }
            mode = .present
            startEngine()
        } else {
            stopListening()
            endSession()
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
            // Keep following at full speed while Keynote or another app is in front.
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Following the speaker")
            // Pauses matter too ("… [0.8 s pause]"), so check on a timer as well as on every word.
            ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
    }

    private func stopListening() {
        listener.stop()
        ticker?.invalidate()
        ticker = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    /// Moves the highlight by hand. Always wins over the judges.
    func select(_ index: Int) {
        guard !matcher.items.isEmpty else { return }
        follower.manual(index, at: now())
        matcher.setCurrent(follower.current)
        tiny?.reset(to: follower.current)
        if current != follower.current { stats.moves["manual", default: 0] += 1 }
        current = follower.current
    }

    func step(_ delta: Int) { select(current + delta) }

    private func now() -> Double { ProcessInfo.processInfo.systemUptime - clockStart }

    // MARK: - Choosing who follows

    /// Sets up the judge and/or tiny model for this presentation, falling back with a clear reason.
    private func startEngine() {
        session = UUID()
        clockStart = ProcessInfo.processInfo.systemUptime
        chunks = []
        lastAskAt = -1e9; lastWordAt = 0; newWords = 0; seq = 0; tinySeq = 0
        judgeInFlight = false; isJudging = false; lastRecheckAt = 0
        judge = nil; tiny = nil; lastTinyVerdict = nil; prep = nil
        tinyChain?.cancel(); tinyChain = nil
        engineNote = nil

        let outline = matcher.items
        let onDevice = OnDevice.status()
        switch followMode {
        case .automatic:
            if onDevice.isReady, let j = OnDevice.makeJudge(rules: AppResources.judgeRules) {
                use(.onDevice, judge: j, cadence: .onDevice)
            } else {
                startTiny(note: "Apple's on-device model: \(onDevice.label.lowercased()).")
            }
        case .onDevice:
            if let j = OnDevice.makeJudge(rules: AppResources.judgeRules) {
                use(.onDevice, judge: j, cadence: .onDevice)
            } else {
                use(.keywords, note: onDevice.message)
            }
        case .tiny:
            startTiny(note: nil)
        case .claude:
            if accessCode.isEmpty {
                use(.keywords, note: "Add your access code in Settings to use Claude.")
            } else {
                use(.claude, judge: ClaudeJudge(model: "haiku", accessCode: accessCode), cadence: .claude)
            }
        case .keywords:
            use(.keywords)
        }
        stats = SessionStats(engine: engine.rawValue)
        if let judge { Task { await judge.prepare(outline: outline, gists: nil) } }
    }

    private func use(_ e: Engine, judge: (any Judge)? = nil, cadence: JudgeCadence = .onDevice, note: String? = nil) {
        engine = e
        self.judge = judge
        self.cadence = cadence
        engineNote = note
        stats.engine = e.rawValue
    }

    /// The tiny meaning model: downloads once, then builds anchors from the outline (plus a gist and
    /// examples written by Apple's model when it's available). Keywords follow until it's ready.
    private func startTiny(note: String?) {
        use(.keywords, note: "Getting the tiny meaning model ready…")
        let s = session
        let outline = matcher.items
        Task {
            await ModelStore.shared.ensure()
            guard s == session else { return }
            guard let embedder = ModelStore.shared.embedder else {
                if case .failed(let why) = ModelStore.shared.state { engineNote = "Couldn't get the tiny meaning model: \(why)" }
                return
            }
            await buildTiny(embedder: embedder, outline: outline, prep: nil, session: s)
            guard s == session, tiny != nil else { return }
            use(.tiny, note: note)
            // Better anchors: Apple's model writes a gist and example sentences per point (in memory only).
            let key = outline.map { "\($0.level)|\($0.text)|\($0.cues.joined(separator: ","))" }.joined(separator: "\n")
            if let cached = prepCache[key] {
                await buildTiny(embedder: embedder, outline: outline, prep: cached, session: s)
            } else if OnDevice.status().isReady, let written = try? await OnDevice.writePrep(outline: outline, rules: AppResources.prepRules) {
                prepCache[key] = written
                await buildTiny(embedder: embedder, outline: outline, prep: written, session: s)
            }
        }
    }

    private func buildTiny(embedder: SentenceEmbedder, outline: [OutlineItem], prep: [PointPrep]?, session s: UUID) async {
        let profile = AppResources.profile("\(ModelStore.profileKey):\(prep == nil ? "bare" : "prep")")
        let t = TinyFollower(embedder: embedder, count: outline.count, profile: profile)
        do { try await t.prepare(outline: outline, prep: prep) } catch { return }
        guard s == session else { return }
        t.reset(to: follower.current)
        tiny = t
        self.prep = prep
    }

    private func fallBack(_ failure: JudgeFailure) {
        stats.fallbacks.append(failure.kind)
        judge = nil
        if engine == .onDevice, followMode == .automatic {
            startTiny(note: failure.message)
        } else {
            use(.keywords, note: failure.message)
        }
    }

    private func endSession() {
        session = UUID()
        judge = nil; tiny = nil
        tinyChain?.cancel()
        isJudging = false
        guard stats.minutes > 0.1 || stats.judgeCalls > 0 else { return }
        lastStats = stats
        if let data = try? JSONEncoder().encode(stats) { UserDefaults.standard.set(data, forKey: "lastSession") }
    }

    // MARK: - Speech

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

    private func feed(_ raw: String) {
        let chunk = Meaning.asrText(raw)
        guard !chunk.isEmpty, mode == .present else { return }
        let t = now()
        chunks.append(TimedChunk(t: t, text: chunk))
        chunks.removeAll { t - $0.t > 60 }
        newWords += chunk.split(separator: " ").count
        lastWordAt = t
        stats.minutes = t / 60

        if engine == .keywords {
            _ = matcher.feed(chunk)
            if follower.keyword(matcher.current, at: t) { moved(by: "keyword") } else if matcher.current != follower.current { matcher.setCurrent(follower.current) }
        }
        if let tiny, engine == .tiny { observeTiny(tiny, at: t) }
        maybeJudge()
    }

    /// Runs the tiny model on every settled chunk, in order.
    private func observeTiny(_ tiny: TinyFollower, at t: Double) {
        let snapshot = chunks, s = session, previous = tinyChain
        tinyChain = Task {
            await previous?.value
            guard s == session else { return }
            let asked = follower.current
            guard let v = try? await tiny.observe(chunks: snapshot, now: t, current: asked), s == session else { return }
            lastTinyVerdict = v
            tinySeq += 1
            let d = follower.verdict(v, seq: tinySeq, askedAt: t, askedCurrent: asked, at: now(), source: "tiny")
            if d.didMove { moved(by: "tiny") }
        }
    }

    private func tick() {
        guard mode == .present else { return }
        stats.minutes = max(stats.minutes, now() / 60)
        // Apple's model may become ready (download finished, Apple Intelligence turned on): switch back to it.
        if followMode != .keywords, followMode != .claude, followMode != .tiny, engine != .onDevice, now() - lastRecheckAt > 30 {
            lastRecheckAt = now()
            if OnDevice.status().isReady, let j = OnDevice.makeJudge(rules: AppResources.judgeRules) {
                tiny = nil
                use(.onDevice, judge: j, cadence: .onDevice)
                let outline = matcher.items
                Task { await j.prepare(outline: outline, gists: nil) }
            }
        }
        maybeJudge()
    }

    // MARK: - Judging

    private func maybeJudge() {
        guard mode == .present, listener.isListening, let judge, !judgeInFlight, !judge.isBusy else { return }
        let t = now()
        guard shouldJudge(now: t, lastAskAt: lastAskAt, lastWordAt: lastWordAt, newWords: newWords, inFlight: false, cadence: cadence) else { return }
        let lines = SpeechWindow.lines(chunks, now: t)
        guard !lines.isEmpty else { return }
        let input = JudgeInput(outline: matcher.items, current: follower.current, lines: lines)
        lastAskAt = t
        newWords = 0
        seq += 1
        let mySeq = seq, asked = follower.current, s = session, timeout = cadence.timeout
        judgeInFlight = true
        isJudging = true
        stats.judgeCalls += 1
        Task {
            let started = ProcessInfo.processInfo.systemUptime
            defer {
                if s == session { judgeInFlight = false; isJudging = false }
            }
            do {
                let reply = try await withDeadline(timeout) { try await judge.judge(input) }
                guard s == session else { return }
                stats.latencies.append(ProcessInfo.processInfo.systemUptime - started)
                if reply.meta.usedFallback { stats.errors["fallback", default: 0] += 1 }
                let d = follower.verdict(reply.verdict, seq: mySeq, askedAt: t, askedCurrent: asked, at: now())
                if d.didMove { moved(by: "judge") }
            } catch {
                guard s == session, !(error is CancellationError) else { return }
                let f = (error as? JudgeFailure) ?? .other(String(describing: error))
                stats.errors[f.kind, default: 0] += 1
                if f == .rateLimited { lastAskAt = now() + 5 }   // back off a little
                if f.endsSession { fallBack(f) }
            }
        }
    }

    private func moved(by source: String) {
        guard current != follower.current else { return }
        current = follower.current
        matcher.setCurrent(current)
        tiny?.reset(to: current)
        stats.moves[source, default: 0] += 1
    }

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
}

/// Counts for one presentation. No speech text, ever.
struct SessionStats: Codable, Equatable {
    var engine: String
    var minutes: Double = 0
    var judgeCalls = 0
    var latencies: [Double] = []
    var errors: [String: Int] = [:]
    var moves: [String: Int] = [:]
    var fallbacks: [String] = []

    func latency(_ q: Double) -> Double? {
        let s = latencies.sorted()
        guard !s.isEmpty else { return nil }
        return s[min(s.count - 1, Int(q * Double(s.count)))]
    }

    var summaryJSON: String {
        var o: [String: Any] = [
            "engine": engine, "minutes": (minutes * 10).rounded() / 10, "judgeCalls": judgeCalls,
            "errors": errors, "moves": moves, "fallbacks": fallbacks, "app": SmartClient.appVersion,
        ]
        if let p50 = latency(0.5), let p90 = latency(0.9) {
            o["latencyP50"] = (p50 * 100).rounded() / 100
            o["latencyP90"] = (p90 * 100).rounded() / 100
        }
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
