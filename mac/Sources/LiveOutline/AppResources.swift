import Foundation
import MatcherCore

/// Files shipped inside the app (copied by scripts/build-app.sh): the judge prompt, the tuned tiny-model
/// profiles, the benchmark talks and the recorded Claude results. During `swift run` they are read
/// straight from the repository instead.
enum AppResources {
    /// Resource name → path in the repository (for development builds).
    private static let repoPaths: [String: String] = [
        "judge-prompt.json": "api/_judge-prompt.json",
        "profiles.json": "eval/profiles.json",
        "splits.json": "eval/splits.json",
        "claude-reference.json": "eval/results/claude-reference.json",
    ]

    private static var repoRoot: URL {
        // mac/Sources/LiveOutline/AppResources.swift → repository root.
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    static func url(_ name: String) -> URL? {
        if let u = Bundle.main.resourceURL?.appendingPathComponent(name), FileManager.default.fileExists(atPath: u.path) { return u }
        let dev = repoRoot.appendingPathComponent(repoPaths[name] ?? "eval/built/" + name.replacingOccurrences(of: "talks/", with: ""))
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    static func data(_ name: String) -> Data? { url(name).flatMap { try? Data(contentsOf: $0) } }

    /// The judge prompt the server uses, so Apple's model and Claude get the same question.
    static let promptSet: JudgePrompt.PromptSet? = data("judge-prompt.json").flatMap { try? JSONDecoder().decode(JudgePrompt.PromptSet.self, from: $0) }

    static var judgeRules: String { promptSet?.currentVariant?.rules ?? "" }
    static var prepRules: String { promptSet?.currentVariant?.prepRules ?? "" }

    /// Tuned settings for the tiny meaning model, keyed like "potion:prep".
    static let profiles: [String: MeaningProfile] = data("profiles.json").flatMap { try? JSONDecoder().decode([String: MeaningProfile].self, from: $0) } ?? [:]

    static func profile(_ key: String) -> MeaningProfile { profiles[key] ?? .default }

    static let splits: (dev: [String], test: [String]) = {
        guard let d = data("splits.json"), let o = try? JSONSerialization.jsonObject(with: d) as? [String: [String]] else { return ([], []) }
        return (o["dev"] ?? [], o["test"] ?? [])
    }()

    /// A benchmark talk by id (Resources/talks/<id>.json).
    static func talkURL(_ id: String) -> URL? { url("talks/\(id).json") }
}
