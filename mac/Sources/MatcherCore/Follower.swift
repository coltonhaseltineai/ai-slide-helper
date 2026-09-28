import Foundation

/// Rules for turning judge verdicts into highlight moves. Twin of eval/tools/follower.js — keep them in step.
public struct FollowPolicy: Equatable, Sendable {
    /// A medium-confidence move to the next point needs an agreeing vote within this many seconds.
    public var mediumAgreeWithin: Double
    /// Votes older than this are forgotten.
    public var voteWindow: Double
    /// After a "same"/"tangent" verdict, keyword-matcher moves are ignored for this long.
    public var keywordVetoWithin: Double
    public var allowKeywordMoves: Bool
    /// The pre-on-device behaviour: only a high-confidence answer moves the highlight.
    public var highOnly: Bool

    public init(mediumAgreeWithin: Double, voteWindow: Double, keywordVetoWithin: Double, allowKeywordMoves: Bool, highOnly: Bool) {
        self.mediumAgreeWithin = mediumAgreeWithin; self.voteWindow = voteWindow
        self.keywordVetoWithin = keywordVetoWithin; self.allowKeywordMoves = allowKeywordMoves; self.highOnly = highOnly
    }

    public static let live = FollowPolicy(mediumAgreeWithin: 6, voteWindow: 10, keywordVetoWithin: 5, allowKeywordMoves: true, highOnly: false)
    public static let statusQuo = FollowPolicy(mediumAgreeWithin: 0, voteWindow: 0, keywordVetoWithin: 0, allowKeywordMoves: true, highOnly: true)
}

public enum FollowDecision: Equatable, Sendable {
    case moved(from: Int, to: Int)
    case held(String)

    public var didMove: Bool { if case .moved = self { return true } else { return false } }
}

public struct Follower: Sendable {
    public private(set) var current: Int
    public let count: Int
    public var policy: FollowPolicy
    private var lastSeq: [String: Int] = [:]
    private var lastManualAt = -Double.infinity
    private var lastHoldAt = -Double.infinity
    private var votes: [(point: Int, confidence: JudgeConfidence, at: Double)] = []

    public init(count: Int, policy: FollowPolicy = .live, current: Int = 0) {
        self.count = count; self.policy = policy; self.current = current
    }

    /// The user moved the highlight by hand. Always wins.
    public mutating func manual(_ point: Int, at: Double) {
        current = min(max(point, 0), max(count - 1, 0))
        lastManualAt = at
        votes = []
    }

    /// The keyword matcher proposes a point. Returns true if the highlight moved.
    public mutating func keyword(_ point: Int, at: Double) -> Bool {
        guard point != current, policy.allowKeywordMoves, at - lastHoldAt >= policy.keywordVetoWithin,
              point >= 0, point < count else { return false }
        current = point
        votes = []
        return true
    }

    /// Applies one verdict. `source` keeps sequence numbers of different verdict streams apart.
    public mutating func verdict(_ v: JudgeVerdict, seq: Int, askedAt: Double, askedCurrent: Int, at: Double,
                                 localSupport: Bool = false, source: String = "judge") -> FollowDecision {
        if seq <= (lastSeq[source] ?? -1) { return .held("stale") }
        lastSeq[source] = seq
        if askedAt < lastManualAt { return .held("manual") }
        if askedCurrent != current { return .held("outdated") }
        guard v.point >= 0, v.point < count else { return .held("invalid") }
        if v.state != .moved || v.point == current {
            if v.state == .same || v.state == .tangent || v.point == current { lastHoldAt = at; votes = [] }
            return .held(v.state == .moved ? "same" : v.state.rawValue)
        }
        if policy.highOnly {
            return v.confidence == .high ? move(to: v.point) : .held("low")
        }
        votes.removeAll { at - $0.at > policy.voteWindow }
        let agreeing = votes.filter { $0.point == v.point && $0.confidence >= .medium }
        votes.append((v.point, v.confidence, at))
        if v.confidence == .low { return .held("low") }
        if v.point - current == 1 {
            if v.confidence == .high { return move(to: v.point) }
            let recent = agreeing.contains { at - $0.at <= policy.mediumAgreeWithin }
            return recent || localSupport ? move(to: v.point) : .held("needs-agreement")
        }
        // Going back or skipping ahead needs two votes.
        return agreeing.isEmpty ? .held("needs-second-vote") : move(to: v.point)
    }

    private mutating func move(to point: Int) -> FollowDecision {
        let from = current
        current = point
        votes = []
        return .moved(from: from, to: point)
    }
}

/// When to ask a judge. Twin of shouldJudge in eval/tools/follower.js.
public struct JudgeCadence: Equatable, Sendable {
    public var minNewWords: Int
    public var pauseWords: Int
    public var pauseAfter: Double
    public var minGap: Double
    public var timeout: Double

    public init(minNewWords: Int, pauseWords: Int, pauseAfter: Double, minGap: Double, timeout: Double) {
        self.minNewWords = minNewWords; self.pauseWords = pauseWords; self.pauseAfter = pauseAfter
        self.minGap = minGap; self.timeout = timeout
    }

    public static let onDevice = JudgeCadence(minNewWords: 5, pauseWords: 2, pauseAfter: 0.8, minGap: 1.0, timeout: 2.5)
    public static let claude = JudgeCadence(minNewWords: 5, pauseWords: 2, pauseAfter: 0.8, minGap: 2.0, timeout: 4.0)
}

public func shouldJudge(now: Double, lastAskAt: Double, lastWordAt: Double, newWords: Int, inFlight: Bool, cadence c: JudgeCadence) -> Bool {
    if inFlight { return false }
    if now - lastAskAt < c.minGap { return false }
    if newWords >= c.minNewWords { return true }
    return newWords >= c.pauseWords && now - lastWordAt >= c.pauseAfter
}
