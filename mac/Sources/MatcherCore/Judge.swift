import Foundation

// A "judge" answers one question about the newest speech: is the speaker still on the shown point,
// have they moved to another point, or is this an aside? Apple's on-device model, Claude, the tiny
// meaning model and the keyword matcher all answer with the same JudgeVerdict, so the same commit
// policy (Follower) and the same benchmark apply to every one of them.

public enum JudgeState: String, Codable, CaseIterable, Sendable {
    case same, moved, tangent, unclear
}

public enum JudgeConfidence: String, Codable, CaseIterable, Sendable, Comparable {
    case low, medium, high

    public var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    public static func < (a: JudgeConfidence, b: JudgeConfidence) -> Bool { a.rank < b.rank }
}

/// One line of recent speech: how many seconds ago it ended, and its text.
public struct SpeechLine: Codable, Equatable, Sendable {
    public var ago: Int
    public var text: String
    public init(ago: Int, text: String) { self.ago = ago; self.text = text }
}

public struct JudgeInput: Sendable {
    public var outline: [OutlineItem]
    /// The point shown now (0-based).
    public var current: Int
    public var lines: [SpeechLine]
    /// Optional one-line gist per point, written from the outline only.
    public var gists: [String]?

    public init(outline: [OutlineItem], current: Int, lines: [SpeechLine], gists: [String]? = nil) {
        self.outline = outline; self.current = current; self.lines = lines; self.gists = gists
    }
}

public struct JudgeVerdict: Codable, Equatable, Sendable {
    public var state: JudgeState
    /// 0-based point being covered now (the shown point unless state == .moved).
    public var point: Int
    public var confidence: JudgeConfidence

    public init(state: JudgeState, point: Int, confidence: JudgeConfidence) {
        self.state = state; self.point = point; self.confidence = confidence
    }
}

public struct JudgeMeta: Codable, Equatable, Sendable {
    public var model: String?
    public var promptTokens: Int?
    public var outputTokens: Int?
    public var serverMs: Int?
    /// True when the on-device model's guardrails forced the plain-text fallback.
    public var usedFallback: Bool
    /// For simulations: pretend the answer took this long (virtual time, no sleeping).
    public var simulatedLatencyMs: Int?

    public init(model: String? = nil, promptTokens: Int? = nil, outputTokens: Int? = nil, serverMs: Int? = nil,
                usedFallback: Bool = false, simulatedLatencyMs: Int? = nil) {
        self.model = model; self.promptTokens = promptTokens; self.outputTokens = outputTokens
        self.serverMs = serverMs; self.usedFallback = usedFallback; self.simulatedLatencyMs = simulatedLatencyMs
    }
}

public struct JudgeReply: Sendable {
    public var verdict: JudgeVerdict
    public var meta: JudgeMeta
    public init(verdict: JudgeVerdict, meta: JudgeMeta = JudgeMeta()) { self.verdict = verdict; self.meta = meta }
}

public enum JudgeFailure: Error, Equatable, Sendable {
    case unavailable(String)   // e.g. Apple Intelligence off; ends judging for this presentation
    case setup(String)         // e.g. wrong access code; ends judging for this presentation
    case guardrail             // the on-device model declined this text
    case context               // prompt too large for the model
    case timeout
    case rateLimited
    case busy
    case badOutput
    case network(String)
    case other(String)

    /// Problems that won't fix themselves by asking again.
    public var endsSession: Bool {
        switch self {
        case .unavailable, .setup: return true
        default: return false
        }
    }

    public var kind: String {
        switch self {
        case .unavailable: return "unavailable"
        case .setup: return "setup"
        case .guardrail: return "guardrail"
        case .context: return "context"
        case .timeout: return "timeout"
        case .rateLimited: return "rateLimited"
        case .busy: return "busy"
        case .badOutput: return "badOutput"
        case .network: return "network"
        case .other: return "other"
        }
    }

    public var message: String {
        switch self {
        case .unavailable(let s), .setup(let s), .network(let s), .other(let s): return s
        case .guardrail: return "The on-device model declined to judge this text."
        case .context: return "The outline is too long for the model."
        case .timeout: return "The judge took too long to answer."
        case .rateLimited: return "The judge is being rate-limited."
        case .busy: return "The judge was still busy."
        case .badOutput: return "The judge gave an answer that couldn't be read."
        }
    }
}

/// Anything that can judge where the speaker is.
@MainActor
public protocol Judge: AnyObject, Sendable {
    var id: String { get }
    /// True from the start of a call until the underlying work really ends (even after a timeout).
    var isBusy: Bool { get }
    /// Called once per presentation (e.g. to prewarm a model or ping a server).
    func prepare(outline: [OutlineItem], gists: [String]?) async
    func judge(_ input: JudgeInput) async throws -> JudgeReply
}
