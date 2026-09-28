import Foundation
import MatcherCore

/// Replays a talk in virtual time: speech arrives chunk by chunk, the judge is asked on its cadence,
/// and each answer lands after its real (or simulated) latency. Twin of runJudge in eval/run.js.
@MainActor
public func runClosedLoop(_ talk: BuiltTalk, judge: (any Judge)?, tiny: TinyFollower?, cadence: JudgeCadence,
                          policy: FollowPolicy = .live, gists: [String]? = nil,
                          progress: ((Double) -> Void)? = nil) async -> TalkRun {
    let outline = talk.outline
    let chunks = talk.timedChunks
    var f = Follower(count: outline.count, policy: policy)
    var moves: [Move] = []
    var seq = 0, tinySeq = 0, calls = 0
    var lastAskAt = -1e9, lastWordAt = 0.0, newWords = 0
    var latencies: [Double] = []
    var errors: [String] = []
    struct Pending { var v: JudgeVerdict; var seq: Int; var askedAt: Double; var askedCurrent: Int; var arrive: Double; var localSupport: Bool }
    var inFlight: Pending?

    func apply(_ d: FollowDecision, _ t: Double) {
        if d.didMove { moves.append(Move(t: t, to: f.current)); tiny?.reset(to: f.current) }
    }
    func flush(_ t: Double) {
        if let a = inFlight, a.arrive <= t {
            inFlight = nil
            apply(f.verdict(a.v, seq: a.seq, askedAt: a.askedAt, askedCurrent: a.askedCurrent, at: a.arrive, localSupport: a.localSupport), a.arrive)
        }
    }

    for (ci, c) in talk.chunks.enumerated() {
        flush(c.t)
        newWords += c.text.split(separator: " ").count
        lastWordAt = c.t
        var tinyVerdict: JudgeVerdict?
        if let tiny {
            tinyVerdict = try? await tiny.observe(chunks: Array(chunks[0...ci]), now: c.t, current: f.current)
            if let tv = tinyVerdict {
                tinySeq += 1
                apply(f.verdict(tv, seq: tinySeq, askedAt: c.t, askedCurrent: f.current, at: c.t, source: "tiny"), c.t)
            }
        }
        progress?(Double(ci + 1) / Double(max(talk.chunks.count, 1)))
        guard let judge else { continue }
        let wantsHelp = tiny == nil || (tinyVerdict.map { $0.state == .unclear || ($0.state == .moved && $0.confidence != .high) } ?? false)
        guard wantsHelp, shouldJudge(now: c.t, lastAskAt: lastAskAt, lastWordAt: lastWordAt, newWords: newWords,
                                     inFlight: inFlight != nil, cadence: cadence) else { continue }
        let input = JudgeInput(outline: outline, current: f.current, lines: SpeechWindow.lines(chunks, now: c.t), gists: gists)
        let started = Date()
        var verdict = JudgeVerdict(state: .unclear, point: f.current, confidence: .low)
        var seconds: Double
        do {
            // A generous hard stop so one stuck call can't stall a benchmark (answers over cadence.timeout count as unclear anyway).
            let reply = try await withDeadline(max(cadence.timeout * 4, 10)) { try await judge.judge(input) }
            verdict = reply.verdict
            seconds = reply.meta.simulatedLatencyMs.map { Double($0) / 1000 } ?? Date().timeIntervalSince(started)
        } catch {
            errors.append((error as? JudgeFailure)?.kind ?? "other")
            seconds = Date().timeIntervalSince(started)
        }
        calls += 1
        latencies.append(seconds)
        lastAskAt = c.t
        newWords = 0
        let timedOut = seconds > cadence.timeout
        let localSupport = tiny.map { $0.topTwo.contains(verdict.point) } ?? false
        seq += 1
        inFlight = Pending(v: timedOut ? JudgeVerdict(state: .unclear, point: f.current, confidence: .low) : verdict,
                           seq: seq, askedAt: c.t, askedCurrent: f.current, arrive: c.t + min(seconds, cadence.timeout),
                           localSupport: localSupport)
    }
    flush(.infinity)
    return TalkRun(talk: talk.id, moves: moves, calls: calls, latencies: latencies, errors: errors, score: scoreTimeline(talk, moves: moves))
}

/// The keyword matcher alone (the app's behaviour before meaning following).
public func runKeywords(_ talk: BuiltTalk) -> TalkRun {
    let m = Matcher(items: talk.outline)
    var moves: [Move] = []
    for c in talk.chunks {
        let before = m.current
        m.feed(c.text)
        if m.current != before { moves.append(Move(t: c.t, to: m.current)) }
    }
    return TalkRun(talk: talk.id, moves: moves, calls: 0, latencies: [], errors: [], score: scoreTimeline(talk, moves: moves))
}

/// The best possible follower: always on the truth, instantly.
public func runOracle(_ talk: BuiltTalk) -> TalkRun {
    var moves: [Move] = []
    var cur = 0
    for s in talk.truth where !([s.index] + s.accept).contains(cur) {
        cur = s.index
        moves.append(Move(t: s.start, to: cur))
    }
    return TalkRun(talk: talk.id, moves: moves, calls: 0, latencies: [], errors: [], score: scoreTimeline(talk, moves: moves))
}

/// A judge that answers from a script (for tests and replays), with simulated latency.
@MainActor
public final class ScriptedJudge: Judge {
    public let id: String
    public private(set) var isBusy = false
    private let answer: (JudgeInput) -> JudgeVerdict
    private let latencyMs: Int

    public init(id: String = "scripted", latencyMs: Int, answer: @escaping (JudgeInput) -> JudgeVerdict) {
        self.id = id; self.latencyMs = latencyMs; self.answer = answer
    }

    public func prepare(outline: [OutlineItem], gists: [String]?) async {}

    public func judge(_ input: JudgeInput) async throws -> JudgeReply {
        JudgeReply(verdict: answer(input), meta: JudgeMeta(simulatedLatencyMs: latencyMs))
    }
}
