import Foundation
import MatcherCore
#if canImport(FoundationModels) && arch(arm64)
import FoundationModels
#endif

/// Whether Apple's on-device model (Foundation Models) can be used on this Mac, and why not.
enum OnDeviceStatus: Equatable, Sendable {
    case ready
    case needsMacOS26
    case notEligible
    case appleIntelligenceOff
    case downloading
    case unsupportedLanguage(String)
    case unknown(String)

    var isReady: Bool { self == .ready }

    /// Won't change without new hardware or a macOS upgrade.
    var isPermanent: Bool { self == .notEligible || self == .needsMacOS26 }

    var label: String {
        switch self {
        case .ready: return "Ready"
        case .needsMacOS26: return "Needs macOS 26"
        case .notEligible: return "Not available on this Mac"
        case .appleIntelligenceOff: return "Apple Intelligence is off"
        case .downloading: return "Downloading"
        case .unsupportedLanguage: return "Language not supported"
        case .unknown: return "Unavailable"
        }
    }

    var message: String {
        switch self {
        case .ready: return "Apple's on-device model is ready. It's free, private and works offline."
        case .needsMacOS26: return "Needs macOS 26 or later on a Mac with Apple silicon."
        case .notEligible: return "Needs a Mac with Apple silicon (M1 or later)."
        case .appleIntelligenceOff: return "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri."
        case .downloading: return "Apple's model is still downloading. It will be ready soon."
        case .unsupportedLanguage(let id): return "Apple's on-device model doesn't support your language (\(id)) yet."
        case .unknown(let why): return "Apple's on-device model isn't available right now (\(why))."
        }
    }

    /// Short machine-readable name for self-tests and benchmark results.
    var code: String {
        switch self {
        case .ready: return "ready"
        case .needsMacOS26: return "needsMacOS26"
        case .notEligible: return "notEligible"
        case .appleIntelligenceOff: return "appleIntelligenceOff"
        case .downloading: return "downloading"
        case .unsupportedLanguage: return "unsupportedLanguage"
        case .unknown: return "unknown"
        }
    }
}

@MainActor
enum OnDevice {
    static func status(locale: Locale = .current) -> OnDeviceStatus {
        #if canImport(FoundationModels) && arch(arm64)
        if #available(macOS 26.0, *) { return FMSupport.status(locale: locale) }
        return .needsMacOS26
        #elseif arch(arm64)
        return .needsMacOS26
        #else
        return .notEligible
        #endif
    }

    /// The model's context window in tokens, when known (nil while it isn't ready).
    static func contextSize() -> Int? {
        #if canImport(FoundationModels) && arch(arm64) && compiler(>=6.3)
        if #available(macOS 26.0, *), status() == .ready {
            let n = SystemLanguageModel.default.contextSize
            return n > 0 ? n : nil
        }
        #endif
        return nil
    }

    static func makeJudge(rules: String) -> (any Judge)? {
        #if canImport(FoundationModels) && arch(arm64)
        if #available(macOS 26.0, *), status() == .ready { return FMJudge(rules: rules) }
        #endif
        return nil
    }

    /// Writes a gist and example sentences per point from the outline (never from speech).
    static func writePrep(outline: [OutlineItem], rules: String) async throws -> [PointPrep] {
        #if canImport(FoundationModels) && arch(arm64)
        if #available(macOS 26.0, *), status() == .ready { return try await FMPrepWriter(rules: rules).write(outline) }
        #endif
        throw JudgeFailure.unavailable(status().message)
    }

    /// Asks the model a trivial question and times it.
    static func checkNow() async -> (status: OnDeviceStatus, seconds: Double?) {
        let s = status()
        #if canImport(FoundationModels) && arch(arm64)
        if #available(macOS 26.0, *), s == .ready {
            let start = Date()
            do {
                let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: "Reply with the single word OK.")
                var o = GenerationOptions()
                o.sampling = .greedy
                o.maximumResponseTokens = 4
                _ = try await session.respond(to: "Are you there?", options: o)
                return (s, Date().timeIntervalSince(start))
            } catch {
                return (.unknown(String(describing: error)), nil)
            }
        }
        #endif
        return (s, nil)
    }
}

#if canImport(FoundationModels) && arch(arm64)
@available(macOS 26.0, *)
enum FMSupport {
    static func status(locale: Locale) -> OnDeviceStatus {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.supportsLocale(locale) ? .ready : .unsupportedLanguage(locale.identifier)
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceOff
        case .unavailable(.deviceNotEligible):
            return .notEligible
        case .unavailable(.modelNotReady):
            return .downloading
        case .unavailable:
            return .unknown("unavailable")
        }
    }

    static func options(maxTokens: Int) -> GenerationOptions {
        var o = GenerationOptions()
        o.sampling = .greedy
        o.maximumResponseTokens = maxTokens
        return o
    }

    /// Maps the framework's errors to the app's failure kinds.
    static func failure(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let f = error as? JudgeFailure { return f }
        guard let e = error as? LanguageModelSession.GenerationError else { return JudgeFailure.other(String(describing: error)) }
        switch e {
        case .guardrailViolation, .refusal: return JudgeFailure.guardrail
        case .exceededContextWindowSize: return JudgeFailure.context
        case .rateLimited: return JudgeFailure.rateLimited
        case .concurrentRequests: return JudgeFailure.busy
        case .assetsUnavailable: return JudgeFailure.unavailable("Apple's model isn't downloaded yet.")
        case .unsupportedLanguageOrLocale: return JudgeFailure.setup("Apple's on-device model doesn't support this language.")
        case .decodingFailure, .unsupportedGuide: return JudgeFailure.badOutput
        @unknown default: return JudgeFailure.other(String(describing: e))
        }
    }

    /// Parses structured output via its JSON form.
    static func json(_ content: GeneratedContent) -> [String: Any]? {
        guard let data = content.jsonString.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Apple's on-device model as a judge. Uses a fresh session per question (a session answers one
/// request at a time and its context fills up), keeping one spare session prewarmed with the outline.
@available(macOS 26.0, *)
@MainActor
final class FMJudge: Judge {
    let id = "on-device"
    private(set) var isBusy = false
    private let rules: String
    private var spare: (key: String, session: LanguageModelSession)?

    init(rules: String) { self.rules = rules }

    private func newSession(prewarmWith prefix: String?) -> LanguageModelSession {
        let s = LanguageModelSession(model: SystemLanguageModel.default, instructions: rules)
        if let prefix { s.prewarm(promptPrefix: Prompt { prefix }) }
        return s
    }

    func prepare(outline: [OutlineItem], gists: [String]?) async {
        let block = JudgePrompt.outlineBlock(outline, current: 0, gists: gists).text
        spare = (block, newSession(prewarmWith: block))
    }

    func judge(_ input: JudgeInput) async throws -> JudgeReply {
        let r = JudgePrompt.render(input)
        let session: LanguageModelSession
        if let s = spare, s.key == r.outlineBlock, !s.session.isResponding { session = s.session } else { session = newSession(prewarmWith: nil) }
        spare = nil
        isBusy = true
        defer {
            isBusy = false
            spare = (r.outlineBlock, newSession(prewarmWith: r.outlineBlock))
        }
        do {
            let schema = try Self.schema(visible: r.visible)
            let response = try await session.respond(to: r.prompt, schema: schema, includeSchemaInPrompt: true,
                                                     options: FMSupport.options(maxTokens: 48))
            guard let d = FMSupport.json(response.content),
                  let state = JudgeState(rawValue: d["state"] as? String ?? ""),
                  let point = Int(d["point"] as? String ?? "") ?? (d["point"] as? Int),
                  let confidence = JudgeConfidence(rawValue: d["confidence"] as? String ?? "") else { throw JudgeFailure.badOutput }
            let v = JudgePrompt.validate(JudgeVerdict(state: state, point: point - 1, confidence: confidence), visible: r.visible, current: input.current)
            return JudgeReply(verdict: v, meta: JudgeMeta(model: "apple-on-device"))
        } catch {
            let f = FMSupport.failure(error)
            guard f as? JudgeFailure == .guardrail else { throw f }
            // Guardrails still apply to structured output; retry once as plain text with permissive guardrails.
            return try await fallback(r, current: input.current)
        }
    }

    private func fallback(_ r: JudgePrompt.Rendered, current: Int) async throws -> JudgeReply {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let s = LanguageModelSession(model: model, instructions: rules + "\nAnswer with exactly three words: state point confidence. For example: moved 4 high")
        do {
            let text = try await s.respond(to: r.prompt, options: FMSupport.options(maxTokens: 12)).content
            guard let v = JudgePrompt.parseLine(text, visible: r.visible, current: current) else { throw JudgeFailure.guardrail }
            return JudgeReply(verdict: v, meta: JudgeMeta(model: "apple-on-device", usedFallback: true))
        } catch {
            throw FMSupport.failure(error)
        }
    }

    static func schema(visible: Range<Int>) throws -> GenerationSchema {
        let root = DynamicGenerationSchema(name: "Verdict", properties: [
            DynamicGenerationSchema.Property(name: "state", schema: DynamicGenerationSchema(name: "State", anyOf: JudgeState.allCases.map(\.rawValue))),
            DynamicGenerationSchema.Property(name: "point", schema: DynamicGenerationSchema(name: "Point", anyOf: visible.map { String($0 + 1) })),
            DynamicGenerationSchema.Property(name: "confidence", schema: DynamicGenerationSchema(name: "Confidence", anyOf: ["low", "medium", "high"])),
        ])
        return try GenerationSchema(root: root, dependencies: [])
    }
}

/// Writes a gist and example sentences per point with the on-device model, a few points per session.
@available(macOS 26.0, *)
@MainActor
struct FMPrepWriter {
    let rules: String

    func write(_ outline: [OutlineItem]) async throws -> [PointPrep] {
        var out: [PointPrep] = []
        var start = 0
        while start < outline.count {
            let end = min(start + 8, outline.count)
            out += try await batch(outline, start..<end)
            start = end
        }
        return out
    }

    private func batch(_ outline: [OutlineItem], _ range: Range<Int>) async throws -> [PointPrep] {
        let k = range.count
        let point = DynamicGenerationSchema(name: "PointPrep", properties: [
            DynamicGenerationSchema.Property(name: "gist", schema: DynamicGenerationSchema(type: String.self)),
            DynamicGenerationSchema.Property(name: "examples", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self), minimumElements: 6, maximumElements: 6)),
        ])
        let root = DynamicGenerationSchema(name: "Prep", properties: [
            DynamicGenerationSchema.Property(name: "points", schema: DynamicGenerationSchema(arrayOf: point, minimumElements: k, maximumElements: k)),
        ])
        let schema = try GenerationSchema(root: root, dependencies: [])
        let lines = outline.enumerated().map { i, it in
            String(repeating: "   ", count: min(it.level, 3)) + "\(i + 1). " + JudgePrompt.clip(JudgePrompt.squash(it.text), 120)
        }
        let prompt = "Outline:\n" + lines.joined(separator: "\n") +
            "\n\nWrite entries only for points \(range.lowerBound + 1) to \(range.upperBound), in order (\(k) entries)."
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: rules)
        do {
            let response = try await session.respond(to: prompt, schema: schema, includeSchemaInPrompt: true, options: FMSupport.options(maxTokens: 1800))
            let pts = (FMSupport.json(response.content)?["points"] as? [[String: Any]]) ?? []
            return (0..<k).map { i in
                let p = i < pts.count ? pts[i] : [:]
                return PointPrep(gist: p["gist"] as? String ?? "", examples: p["examples"] as? [String] ?? [])
            }
        } catch {
            throw FMSupport.failure(error)
        }
    }
}
#endif
