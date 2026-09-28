import Foundation
import MatcherCore

/// Claude (via the Live Outline server) as a judge. `model` is "haiku" or "sonnet".
@MainActor
final class ClaudeJudge: Judge {
    let id: String
    private(set) var isBusy = false
    private let client: SmartClient
    private let model: String
    private let variant: String?
    private let timeout: Double

    init(model: String = "haiku", accessCode: String, variant: String? = nil, timeout: Double = JudgeCadence.claude.timeout + 1) {
        self.id = model
        self.model = model
        self.client = SmartClient(accessCode: accessCode)
        self.variant = variant
        self.timeout = timeout
    }

    func prepare(outline: [OutlineItem], gists: [String]?) async {
        _ = try? await client.ping()   // warms up the connection and the server function
    }

    func judge(_ input: JudgeInput) async throws -> JudgeReply {
        isBusy = true
        defer { isBusy = false }
        do {
            let r = try await client.judge(input, model: model, variant: variant, timeout: timeout)
            let v = JudgeVerdict(state: JudgeState(rawValue: r.state) ?? .unclear, point: r.point,
                                 confidence: JudgeConfidence(rawValue: r.confidence) ?? .low)
            let visible = JudgePrompt.visibleRange(count: input.outline.count, current: input.current)
            return JudgeReply(verdict: JudgePrompt.validate(v, visible: visible, current: input.current),
                              meta: JudgeMeta(model: r.model, promptTokens: r.usage?.input, outputTokens: r.usage?.output, serverMs: r.serverMs))
        } catch let e as SmartClient.APIError {
            if e.status == 404 { throw JudgeFailure.setup("Claude following isn't set up on the server yet.") }
            if e.status == 503 { throw JudgeFailure.rateLimited }
            if e.isSetupProblem { throw JudgeFailure.setup(e.message) }
            throw JudgeFailure.network(e.message)
        } catch let e as URLError {
            if e.code == .timedOut { throw JudgeFailure.timeout }
            throw JudgeFailure.network(e.localizedDescription)
        }
    }
}
