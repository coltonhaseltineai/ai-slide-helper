import Foundation

/// A highlight move during a replay: at time t the highlight went to point `to`.
public struct Move: Codable, Equatable, Sendable {
    public var t: Double
    public var to: Int
    public init(t: Double, to: Int) { self.t = t; self.to = to }
}

public struct TalkScore: Codable, Equatable, Sendable {
    public var onCorrect: Double
    public var lags: [Double]
    public var missed: Int
    public var switches: Int
    public var wrongMoves: Int
    public var flicker: Int
    public var moves: Int
    public var minutes: Double
}

/// Twin of scoreTimeline in eval/run.js.
public func scoreTimeline(_ talk: BuiltTalk, moves: [Move]) -> TalkScore {
    let dt = 0.25
    var on = 0, total = 0, mi = 0, cur = 0
    var t = 0.0
    while t < talk.duration {
        while mi < moves.count && moves[mi].t <= t { cur = moves[mi].to; mi += 1 }
        total += 1
        if talk.acceptable(at: t).contains(cur) { on += 1 }
        t += dt
    }
    func highlight(at x: Double) -> Int {
        var c = 0
        for m in moves { if m.t <= x { c = m.to } else { break } }
        return c
    }
    var lags: [Double] = []
    var missed = 0
    let tr = talk.truth
    for i in tr.indices where i > 0 {
        let s = tr[i], prev = tr[i - 1]
        guard ["on", "goback", "skip", "resume"].contains(s.kind) else { continue }
        if ([prev.index] + prev.accept).contains(s.index) { continue }
        var end = talk.duration
        for j in (i + 1)..<max(i + 1, tr.count) where tr[j].index != s.index && !tr[j].accept.contains(s.index) { end = tr[j].start; break }
        if highlight(at: s.start) == s.index { lags.append(0); continue }
        if let hit = moves.first(where: { $0.t >= s.start && $0.t < end && $0.to == s.index }) { lags.append(hit.t - s.start) } else { missed += 1 }
    }
    var wrong = 0, flicker = 0
    for (i, m) in moves.enumerated() {
        if !talk.acceptable(at: m.t + 0.01).contains(m.to) { wrong += 1 }
        let prevTo = i > 0 ? moves[i - 1].to : 0
        if i + 1 < moves.count, moves[i + 1].t - m.t <= 5, moves[i + 1].to == prevTo { flicker += 1 }
    }
    return TalkScore(onCorrect: total > 0 ? Double(on) / Double(total) : 0, lags: lags, missed: missed, switches: lags.count + missed,
                     wrongMoves: wrong, flicker: flicker, moves: moves.count, minutes: talk.duration / 60)
}

/// One contender's results over several talks (twin of summarize in eval/run.js).
public struct Summary: Codable, Equatable, Sendable {
    public var contender: String
    public var onCorrect: Double
    public var lagP50: Double
    public var lagP90: Double
    public var missed: Int
    public var switches: Int
    public var wrongPer10: Double
    public var flickerPer10: Double
    public var callsPerMin: Double
    public var latP50: Double
    public var latP90: Double
    public var latMax: Double
    public var errors: Int
    public var errorKinds: [String: Int]
    public var perTalk: [String: Double]
}

public struct TalkRun: Sendable {
    public var talk: String
    public var moves: [Move]
    public var calls: Int
    public var latencies: [Double]
    public var errors: [String]
    public var score: TalkScore

    public init(talk: String, moves: [Move], calls: Int, latencies: [Double], errors: [String], score: TalkScore) {
        self.talk = talk; self.moves = moves; self.calls = calls; self.latencies = latencies; self.errors = errors; self.score = score
    }
}

func quantile(_ sorted: [Double], _ q: Double) -> Double {
    guard !sorted.isEmpty else { return .nan }
    return sorted[min(sorted.count - 1, Int(q * Double(sorted.count)))]
}

func round1(_ x: Double) -> Double { x.isNaN ? x : (x * 10).rounded() / 10 }
func round2(_ x: Double) -> Double { x.isNaN ? x : (x * 100).rounded() / 100 }

public func summarize(_ name: String, _ runs: [TalkRun]) -> Summary {
    let lags = runs.flatMap { $0.score.lags }.sorted()
    let minutes = runs.reduce(0) { $0 + $1.score.minutes }
    let lat = runs.flatMap { $0.latencies }.sorted()
    let calls = runs.reduce(0) { $0 + $1.calls }
    var kinds: [String: Int] = [:]
    for r in runs { for e in r.errors { kinds[e, default: 0] += 1 } }
    return Summary(
        contender: name,
        onCorrect: round1(100 * runs.reduce(0) { $0 + $1.score.onCorrect * $1.score.minutes } / max(minutes, 1e-9)),
        lagP50: round1(quantile(lags, 0.5)), lagP90: round1(quantile(lags, 0.9)),
        missed: runs.reduce(0) { $0 + $1.score.missed }, switches: runs.reduce(0) { $0 + $1.score.switches },
        wrongPer10: round1(10 * Double(runs.reduce(0) { $0 + $1.score.wrongMoves }) / max(minutes, 1e-9)),
        flickerPer10: round1(10 * Double(runs.reduce(0) { $0 + $1.score.flicker }) / max(minutes, 1e-9)),
        callsPerMin: round1(Double(calls) / max(minutes, 1e-9)),
        latP50: round2(quantile(lat, 0.5)), latP90: round2(quantile(lat, 0.9)), latMax: round2(lat.last ?? .nan),
        errors: runs.reduce(0) { $0 + $1.errors.count }, errorKinds: kinds,
        perTalk: Dictionary(uniqueKeysWithValues: runs.map { ($0.talk, (100 * $0.score.onCorrect).rounded()) })
    )
}
