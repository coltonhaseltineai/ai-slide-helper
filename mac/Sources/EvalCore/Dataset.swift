import Foundation
import MatcherCore

/// A benchmark talk as produced by eval/tools/build.js (schema live-outline-built/1).
public struct BuiltTalk: Codable, Sendable {
    public struct Item: Codable, Sendable { public var text: String; public var level: Int; public var cues: [String] }
    public struct Chunk: Codable, Sendable { public var t: Double; public var text: String; public var seg: Int }
    public struct Truth: Codable, Sendable { public var start: Double; public var end: Double; public var index: Int; public var accept: [Int]; public var kind: String }
    public struct Tick: Codable, Sendable {
        public var i: Int; public var t: Double; public var seg: Int; public var kind: String
        public var current: Int; public var truth: Int; public var accept: [Int]; public var transition: Bool
        public var lines: [SpeechLine]
    }

    public var schema: String
    public var id: String
    public var title: String
    public var tier: String
    public var items: [Item]
    public var duration: Double
    public var chunks: [Chunk]
    public var truth: [Truth]
    public var ticks: [Tick]

    public var outline: [OutlineItem] { items.enumerated().map { OutlineItem(id: $0, text: $1.text, cues: $1.cues, level: $1.level) } }
    public var timedChunks: [TimedChunk] { chunks.map { TimedChunk(t: $0.t, text: $0.text) } }

    public static func load(_ url: URL) throws -> BuiltTalk { try JSONDecoder().decode(BuiltTalk.self, from: Data(contentsOf: url)) }

    /// Acceptable points at time t (the truth plus any "either is fine" points).
    public func acceptable(at t: Double) -> [Int] {
        for s in truth where t < s.end { return [s.index] + s.accept }
        guard let s = truth.last else { return [] }
        return [s.index] + s.accept
    }
}

/// The dev/test split (eval/splits.json).
public struct Splits: Codable, Sendable {
    public var dev: [String]
    public var test: [String]
}
