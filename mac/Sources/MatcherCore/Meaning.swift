import Foundation

// Tiny-model meaning follower. Each outline point gets "anchors" — its text plus a gist and example
// sentences written from the outline (never from speech) — and recent speech is compared with them.
// Twin of eval/tools/meaning.js; the benchmark tunes MeaningProfile per embedding model.

public struct MeaningProfile: Codable, Equatable, Sendable {
    public var temperature: Double
    public var alpha: Double
    public var stay: Double, next: Double, skip2: Double, back1: Double, other: Double
    public var shortWeight: Double
    public var tangentFloor: Double
    public var highBelief: Double, highMargin: Double, midBelief: Double, midMargin: Double

    public init(temperature: Double = 0.05, alpha: Double = 0.5, stay: Double = 0.9, next: Double = 0.07, skip2: Double = 0.015,
                back1: Double = 0.01, other: Double = 0.005, shortWeight: Double = 0.35, tangentFloor: Double = -1,
                highBelief: Double = 0.7, highMargin: Double = 0.3, midBelief: Double = 0.5, midMargin: Double = 0.15) {
        self.temperature = temperature; self.alpha = alpha
        self.stay = stay; self.next = next; self.skip2 = skip2; self.back1 = back1; self.other = other
        self.shortWeight = shortWeight; self.tangentFloor = tangentFloor
        self.highBelief = highBelief; self.highMargin = highMargin; self.midBelief = midBelief; self.midMargin = midMargin
    }

    public static let `default` = MeaningProfile()
}

/// Per-point preparation written from the outline: a one-line gist and example spoken sentences.
public struct PointPrep: Codable, Equatable, Sendable {
    public var gist: String
    public var examples: [String]
    public init(gist: String, examples: [String]) { self.gist = gist; self.examples = examples }
}

public enum Meaning {
    /// Lowercase, no punctuation — the way speech-to-text text looks (addsPunctuation = false).
    public static func asrText(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var space = false
        for u in s.lowercased().unicodeScalars {
            let keep = (u >= "a" && u <= "z") || (u >= "0" && u <= "9") || u == "'"
            let mapped: Unicode.Scalar = (u == "’") ? "'" : u
            if keep || mapped == "'" {
                if space && !out.isEmpty { out.append(" ") }
                space = false
                out.append(mapped)
            } else {
                space = true
            }
        }
        return String(out)
    }

    /// Anchor texts for each point: its parent, text and cues, then gist and examples when available.
    public static func anchorTexts(_ items: [OutlineItem], prep: [PointPrep?]?) -> [[String]] {
        items.enumerated().map { i, it in
            var parent = ""
            var j = i - 1
            while j >= 0 { if items[j].level < it.level { parent = items[j].text; break }; j -= 1 }
            let base = ([parent, it.text] + it.cues).filter { !$0.isEmpty }.joined(separator: " ")
            var out = [asrText(base)]
            if let prep, i < prep.count, let p = prep[i] {
                if !p.gist.isEmpty { out.append(asrText(p.gist)) }
                out += p.examples.map(asrText)
            }
            return out.filter { !$0.isEmpty }
        }
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        var s: Float = 0
        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
        return Double(s)
    }

    static func median(_ a: [Double]) -> Double {
        let s = a.sorted()
        guard !s.isEmpty else { return 0 }
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }
}

/// Scores recent speech against each point's anchor vectors (L2-normalised).
public struct MeaningScorer: Sendable {
    public let anchors: [[[Float]]]

    public init(anchorVectors: [[[Float]]]) { anchors = anchorVectors }

    public struct Scores: Equatable, Sendable {
        public var short: [Double]
        public var long: [Double]
        public var maxLong: Double
        public init(short: [Double], long: [Double], maxLong: Double) { self.short = short; self.long = long; self.maxLong = maxLong }
    }

    /// Per point: mean of the top-2 anchor similarities.
    public func raw(_ v: [Float]) -> [Double] {
        anchors.map { vs in
            let s = vs.map { Meaning.cosine(v, $0) }.sorted(by: >)
            guard let first = s.first else { return 0 }
            return s.count > 1 ? (first + s[1]) / 2 : first
        }
    }

    public func score(short: [Float], long: [Float]) -> Scores {
        let rs = raw(short), rl = raw(long)
        let ms = Meaning.median(rs), ml = Meaning.median(rl)
        return Scores(short: rs.map { $0 - ms }, long: rl.map { $0 - ml }, maxLong: rl.max() ?? 0)
    }
}

/// Keeps a belief over points (favouring staying and moving forward) and turns it into a verdict.
public struct MeaningTracker: Sendable {
    public private(set) var belief: [Double]
    public var profile: MeaningProfile

    public struct State: Equatable, Sendable {
        public var tangent: Bool
        public var best: Int
    }

    public init(count: Int, profile: MeaningProfile, start: Int = 0) {
        self.profile = profile
        belief = (0..<count).map { $0 == start ? 1 : 0 }
    }

    public mutating func reset(to point: Int) { belief = belief.indices.map { $0 == point ? 1 : 0 } }

    func transition(_ i: Int, _ j: Int) -> Double {
        let p = profile
        switch j - i {
        case 0: return p.stay
        case 1: return p.next
        case 2: return p.skip2
        case -1: return p.back1
        default: return p.other
        }
    }

    public mutating func update(_ s: MeaningScorer.Scores) -> State {
        let p = profile
        let tangent = s.maxLong < p.tangentFloor
        let like: [Double]
        if tangent {
            like = belief.map { _ in 1 }
        } else {
            let z = s.short.indices.map { p.shortWeight * s.short[$0] + (1 - p.shortWeight) * s.long[$0] }
            let mx = z.max() ?? 0
            let e = z.map { exp(($0 - mx) / p.temperature) }
            let sum = e.reduce(0, +)
            like = e.map { pow($0 / sum, p.alpha) }
        }
        let prior = belief.indices.map { j in belief.indices.reduce(0.0) { $0 + belief[$1] * transition($1, j) } }
        let post = prior.indices.map { prior[$0] * like[$0] }
        let total = post.reduce(0, +)
        belief = post.map { $0 / (total > 0 ? total : 1) }
        var best = 0
        for i in belief.indices where belief[i] > belief[best] { best = i }
        return State(tangent: tangent, best: best)
    }

    /// A judge-style verdict relative to the shown point.
    public func verdict(current: Int, state: State) -> JudgeVerdict {
        let p = profile
        if state.tangent { return JudgeVerdict(state: .tangent, point: current, confidence: .medium) }
        let best = state.best
        if best == current { return JudgeVerdict(state: .same, point: current, confidence: belief[best] >= p.highBelief ? .high : .medium) }
        let margin = belief[best] - belief[current]
        if belief[best] >= p.highBelief && margin >= p.highMargin { return JudgeVerdict(state: .moved, point: best, confidence: .high) }
        if belief[best] >= p.midBelief && margin >= p.midMargin { return JudgeVerdict(state: .moved, point: best, confidence: .medium) }
        return JudgeVerdict(state: .unclear, point: current, confidence: .low)
    }

    /// The two most likely points (for "local support" of a judge's answer).
    public var topTwo: [Int] { Array(belief.indices.sorted { belief[$0] > belief[$1] }.prefix(2)) }
}
