import CryptoKit
import Foundation
import MatcherCore
import NaturalLanguage
import Observation

/// Apple's built-in sentence embedding (no download). A zero-cost baseline for the tiny-model follower.
final class NLSentenceEmbedder: SentenceEmbedder, @unchecked Sendable {
    let id = "apple-nl"
    let dimension: Int
    private let embedding: NLEmbedding
    private let lock = NSLock()

    init?() {
        guard let e = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        embedding = e
        dimension = e.dimension
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        lock.lock()
        defer { lock.unlock() }
        return texts.map { t in
            let v = embedding.vector(for: t) ?? Array(repeating: 0, count: dimension)
            return l2Normalize(v.map(Float.init))
        }
    }
}

/// Downloads the tiny meaning model once (from this project's "models-v1" GitHub release),
/// checks its SHA-256, and keeps it in ~/Library/Application Support/Live Outline/Models.
@MainActor
@Observable
final class ModelStore {
    enum State: Equatable {
        case notDownloaded
        case downloading
        case ready
        case failed(String)
    }

    struct Manifest: Decodable {
        struct File: Decodable { let name: String; let sha256: String; let bytes: Int }
        let id: String
        let dimension: Int
        let format: String   // "f16"
        let weights: String
        let vocab: String
        let files: [File]
    }

    static let shared = ModelStore()
    static let release = URL(string: "https://github.com/coltonhaseltineai/ai-slide-helper/releases/download/models-v1/")!
    static let modelID = "potion-base-8M"
    /// Which tuned profile in eval/profiles.json fits this model ("potion:prep" / "potion:bare").
    static let profileKey = "potion"

    private(set) var state: State = .notDownloaded
    private(set) var embedder: SentenceEmbedder?
    private var task: Task<Void, Never>?

    private var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Live Outline/Models/\(Self.modelID)", isDirectory: true)
    }

    /// Loads the model, downloading it first if needed. Safe to call repeatedly.
    func ensure() async {
        if embedder != nil { return }
        if let task { await task.value; return }
        let t = Task { await self.load() }
        task = t
        await t.value
        task = nil
    }

    private func load() async {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let manifestURL = folder.appendingPathComponent("manifest.json")
            if !fm.fileExists(atPath: manifestURL.path) {
                state = .downloading
                try await download(Self.release.appendingPathComponent("manifest.json"), to: manifestURL, sha256: nil)
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            for f in manifest.files {
                let dest = folder.appendingPathComponent(f.name)
                if fm.fileExists(atPath: dest.path), (try? Self.sha256(of: dest)) == f.sha256 { continue }
                state = .downloading
                try await download(Self.release.appendingPathComponent(f.name), to: dest, sha256: f.sha256)
            }
            let weights = try Data(contentsOf: folder.appendingPathComponent(manifest.weights))
            let vocab = try String(contentsOf: folder.appendingPathComponent(manifest.vocab), encoding: .utf8)
            let e = try StaticEmbedder(id: manifest.id, weights: weights, vocabText: vocab, dimension: manifest.dimension, float32: manifest.format == "f32")
            embedder = e
            state = .ready
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    private func download(_ url: URL, to dest: URL, sha256: String?) async throws {
        let (tmp, response) = try await URLSession.shared.download(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw EmbeddingError.unavailable("Model download failed (\(status)).") }
        if let sha256, try Self.sha256(of: tmp) != sha256 { throw EmbeddingError.badModelFile("checksum mismatch") }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}
