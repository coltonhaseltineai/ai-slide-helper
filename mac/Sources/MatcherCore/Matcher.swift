import Foundation

/// One line of the outline.
public struct OutlineItem: Equatable, Identifiable, Sendable {
    public let id: Int
    public let text: String
    public let cues: [String]
    public let level: Int

    public init(id: Int, text: String, cues: [String] = [], level: Int = 0) {
        self.id = id
        self.text = text
        self.cues = cues
        self.level = level
    }
}

private let stopwords: Set<String> = Set(("a an the and or but if then so of to in on at by for with from as is are was were be been " +
    "it its this that these those i you he she we they me my our your their them us do does did have has had " +
    "not no yes just about into over out up down very really can will would should could what which who how " +
    "when where why all any some more most other such than too also there here now um uh like okay ok well right")
    .split(separator: " ").map(String.init))

func stem(_ w: String) -> String {
    if w.count > 5 && w.hasSuffix("ing") { return String(w.dropLast(3)) }
    if w.count > 4 && w.hasSuffix("ed") { return String(w.dropLast(2)) }
    if w.count > 4 && w.hasSuffix("ies") { return String(w.dropLast(3)) + "y" }
    if w.count > 3 && w.hasSuffix("s") && !w.hasSuffix("ss") { return String(w.dropLast()) }
    return w
}

/// Lowercases, strips punctuation, drops filler words and lightly stems.
public func tokenize(_ text: String) -> [String] {
    let cleaned = text.lowercased()
        .replacingOccurrences(of: "'", with: "")
        .replacingOccurrences(of: "’", with: "")
        .map { ($0.isLetter || $0.isNumber) ? $0 : " " }
    return String(cleaned).split(separator: " ")
        .map(String.init)
        .filter { !stopwords.contains($0) }
        .map(stem)
}

/// Parses an indented outline. Lines may include `[cues: a, b]`.
public func parseOutline(_ text: String) -> [OutlineItem] {
    var raw: [(text: String, cues: [String], indent: Int)] = []
    for line in text.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        var indent = 0
        for ch in line {
            if ch == " " { indent += 1 } else if ch == "\t" { indent += 2 } else { break }
        }
        var body = trimmed
        if let r = body.range(of: #"^([-*•]|\d+[.)])\s+"#, options: .regularExpression) {
            body.removeSubrange(r)
        }
        var cues: [String] = []
        if let r = body.range(of: #"\[cues?:[^\]]*\]"#, options: [.regularExpression, .caseInsensitive]) {
            let tag = body[r]
            let inner = tag.dropFirst().dropLast().split(separator: ":", maxSplits: 1).last ?? ""
            cues = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            body.removeSubrange(r)
        }
        raw.append((body.trimmingCharacters(in: .whitespaces), cues, indent))
    }
    let levels = Array(Set(raw.map(\.indent))).sorted()
    return raw.enumerated().map { i, r in
        OutlineItem(id: i, text: r.text, cues: r.cues, level: levels.firstIndex(of: r.indent) ?? 0)
    }
}

/// Figures out which outline item the speaker is currently on.
public final class Matcher {
    public struct Options: Sendable {
        public var window = 25
        public var margin = 0.15
        public var confirm = 2
        public init() {}
    }

    public let items: [OutlineItem]
    public private(set) var current: Int
    private var keywords: [Set<String>]
    private var learned: [Set<String>]
    private var docFreq: [String: Int]
    private let options: Options
    private var words: [String] = []
    private var pending: Int?
    private var pendingCount = 0

    public init(items: [OutlineItem], options: Options = Options()) {
        self.items = items
        self.options = options
        self.keywords = items.map { Set(tokenize($0.text) + $0.cues.flatMap(tokenize)) }
        self.learned = items.map { _ in [] }
        var df: [String: Int] = [:]
        for set in keywords { for k in set { df[k, default: 0] += 1 } }
        self.docFreq = df
        self.current = items.isEmpty ? -1 : 0
    }

    private func idf(_ k: String) -> Double {
        log(1 + Double(max(items.count, 1)) / Double(docFreq[k] ?? 1))
    }

    public enum KeywordSource: Sendable { case hint, learned }

    /// Adds hint words, or words the speaker was heard using, to one item. Returns how many were new.
    @discardableResult
    public func addKeywords(_ i: Int, _ words: [String], source: KeywordSource = .hint) -> Int {
        guard items.indices.contains(i) else { return 0 }
        var added = 0
        for k in tokenize(words.joined(separator: " ")) {
            if source == .learned { learned[i].insert(k) }
            if keywords[i].contains(k) { continue }
            keywords[i].insert(k)
            docFreq[k, default: 0] += 1
            added += 1
        }
        return added
    }

    /// How many words in `text` belong to item i.
    public func hits(_ i: Int, _ text: String) -> Int {
        guard items.indices.contains(i) else { return 0 }
        return tokenize(text).filter { keywords[i].contains($0) }.count
    }

    /// Moves the highlight manually; matching continues from here.
    public func setCurrent(_ i: Int) {
        guard !items.isEmpty else { return }
        current = min(max(i, 0), items.count - 1)
        pending = nil
        pendingCount = 0
        words = []
    }

    func score(_ i: Int) -> Double {
        let kws = keywords[i]
        guard !kws.isEmpty else { return 0 }
        // Each keyword counts once, weighted by how recently it was said (older words fade).
        var recency: [String: Double] = [:]
        let n = words.count
        for (idx, w) in words.enumerated() where kws.contains(w) {
            recency[w] = pow(0.85, Double(n - 1 - idx))
        }
        var s = recency.reduce(0) { $0 + idf($1.key) * $1.value * (learned[i].contains($1.key) ? 1.25 : 1) }
        // Hint lists can be long, so dampen length less than plain line text would.
        s /= pow(Double(kws.count), 0.35)
        let d = i - current
        if d == 0 || d == 1 { s *= 1.3 }
        else if d < 0 { s *= 0.6 }
        else { s *= max(0.4, 1 - 0.1 * Double(d - 1)) }
        return s
    }

    /// Feeds newly spoken words; returns the current index.
    @discardableResult
    public func feed(_ text: String) -> Int {
        words.append(contentsOf: tokenize(text))
        if words.count > options.window { words = Array(words.suffix(options.window)) }
        guard !items.isEmpty else { return -1 }
        var best = current
        var bestScore = -1.0
        for i in items.indices {
            let s = score(i)
            if s > bestScore { bestScore = s; best = i }
        }
        let cur = score(current)
        if best != current && bestScore > 0 && bestScore > cur * (1 + options.margin) + 0.05 {
            if pending == best { pendingCount += 1 } else { pending = best; pendingCount = 1 }
            if pendingCount >= options.confirm { setCurrent(best) }
        } else {
            pending = nil
            pendingCount = 0
        }
        return current
    }
}

/// Remembers hint words and learned words per outline line, across talks.
public struct LearnedLibrary: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var hints: [String] = []
        public var learned: [String: Double] = [:]   // word -> when it was last heard
    }

    public var entries: [String: Entry] = [:]
    public var cap = 60

    public init() {}

    public static func lineKey(_ text: String) -> String {
        let k = tokenize(text).joined(separator: " ")
        return k.isEmpty ? text.lowercased().trimmingCharacters(in: .whitespaces) : k
    }

    public func has(_ text: String) -> Bool { !(entries[Self.lineKey(text)]?.hints.isEmpty ?? true) }

    public func words(_ text: String) -> (hints: [String], learned: [String]) {
        guard let e = entries[Self.lineKey(text)] else { return ([], []) }
        return (e.hints, Array(e.learned.keys))
    }

    public mutating func setHints(_ text: String, _ words: [String]) {
        var seen = Set<String>()
        entries[Self.lineKey(text), default: Entry()].hints = Array(words.filter { seen.insert($0).inserted }.prefix(40))
    }

    /// Returns how many words were new.
    @discardableResult
    public mutating func addLearned(_ text: String, _ words: [String], now: Double = Date().timeIntervalSince1970) -> Int {
        let key = Self.lineKey(text)
        var e = entries[key, default: Entry()]
        var added = 0
        for w in words {
            let k = w.lowercased().trimmingCharacters(in: .whitespaces)
            if k.isEmpty { continue }
            if e.learned[k] == nil { added += 1 }
            e.learned[k] = now
        }
        if e.learned.count > cap {
            let keep = e.learned.sorted { $0.value > $1.value }.prefix(cap)
            e.learned = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        entries[key] = e
        return added
    }

    public var learnedCount: Int { entries.values.reduce(0) { $0 + $1.learned.count } }
}

/// Decides when to ask Claude where the speaker is: only when the local matcher seems unsure,
/// plus an occasional check, and never while a request is already running. Times are in seconds.
public func shouldLocate(now: Double, lastCallAt: Double, lastConfidentAt: Double, newWords: Int, inFlight: Bool,
                         unsureAfter: Double = 6, every: Double = 10, minGap: Double = 3, minWords: Int = 8) -> Bool {
    if inFlight || newWords < minWords { return false }
    if now - lastCallAt < minGap { return false }
    return now - lastConfidentAt >= unsureAfter || now - lastCallAt >= every
}
