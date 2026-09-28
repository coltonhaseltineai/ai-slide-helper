import Foundation
import MatcherCore

/// Talks to the Live Outline server (/api/follow), which asks Claude.
struct SmartClient: Sendable {
    static let baseURL = URL(string: "https://live-outline.vercel.app")!

    struct APIError: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { message }
        /// Setup problems (bad code, no key, route missing) won't fix themselves by retrying.
        var isSetupProblem: Bool { [400, 401, 404, 500].contains(status) }
    }

    struct FollowResponse: Decodable {
        struct Usage: Decodable { let input: Int?; let output: Int? }
        let state: String
        let point: Int
        let confidence: String
        let model: String?
        let serverMs: Int?
        let usage: Usage?
        let promptVersion: String?
    }

    struct PrepResponse: Decodable { let points: [PointPrep] }
    struct PingResponse: Decodable { let ok: Bool?; let promptVersion: String? }

    var accessCode: String

    static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    private static func body(_ input: JudgeInput) -> [String: Any] {
        var b: [String: Any] = [
            "items": input.outline.map { ["text": $0.text, "level": $0.level, "cues": $0.cues] as [String: Any] },
            "current": input.current,
            "lines": input.lines.map { ["ago": $0.ago, "text": $0.text] as [String: Any] },
        ]
        if let g = input.gists { b["gists"] = g }
        return b
    }

    func judge(_ input: JudgeInput, model: String, variant: String? = nil, timeout: Double) async throws -> FollowResponse {
        var b = Self.body(input)
        b["op"] = "judge"
        b["model"] = model
        if let variant { b["variant"] = variant }
        return try await post(b, timeout: timeout)
    }

    func prep(_ outline: [OutlineItem]) async throws -> [PointPrep] {
        var b = Self.body(JudgeInput(outline: outline, current: 0, lines: []))
        b["op"] = "prep"
        b["model"] = "sonnet"
        let r: PrepResponse = try await post(b, timeout: 60)
        return r.points
    }

    func ping() async throws -> (promptVersion: String?, seconds: Double) {
        let start = Date()
        let r: PingResponse = try await post(["op": "ping"], timeout: 8)
        return (r.promptVersion, Date().timeIntervalSince(start))
    }

    private func post<T: Decodable>(_ body: [String: Any], timeout: Double) async throws -> T {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/follow"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload = body
        payload["code"] = accessCode
        payload["v"] = Self.appVersion
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw APIError(status: status, message: message ?? "Request failed (\(status)).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
