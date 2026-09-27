import Foundation

/// Talks to the Live Outline server, which asks Claude for help.
struct SmartClient {
    static let baseURL = URL(string: "https://live-outline.vercel.app")!

    struct APIError: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { message }
        /// Setup problems (bad code, no key) won't fix themselves by retrying.
        var isSetupProblem: Bool { [400, 401, 404, 500].contains(status) }
    }

    struct ExpandResponse: Decodable { let hints: [[String]] }
    struct LocateResponse: Decodable {
        let index: Int
        let confidence: String
        let learned: [String]
    }

    var accessCode: String

    func expand(items: [String]) async throws -> ExpandResponse {
        try await post("api/expand", ["items": items])
    }

    func locate(items: [String], current: Int, transcript: String, known: Int? = nil) async throws -> LocateResponse {
        var body: [String: Any] = ["items": items, "current": current, "transcript": transcript]
        if let known { body["known"] = known }
        return try await post("api/locate", body)
    }

    private func post<T: Decodable>(_ path: String, _ body: [String: Any]) async throws -> T {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload = body
        payload["code"] = accessCode
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
