import Foundation

/// Turns text into an L2-normalised sentence vector.
public protocol SentenceEmbedder: AnyObject, Sendable {
    var id: String { get }
    var dimension: Int { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

public enum EmbeddingError: Error, Equatable {
    case badModelFile(String)
    case unavailable(String)
}

public func l2Normalize(_ v: [Float]) -> [Float] {
    var s: Float = 0
    for x in v { s += x * x }
    let n = s.squareRoot()
    return n > 1e-12 ? v.map { $0 / n } : v
}

/// Converts IEEE half-precision bits to Float (portable: Float16 isn't available on Intel Macs).
@inline(__always) public func halfToFloat(_ h: UInt16) -> Float {
    let sign = UInt32(h & 0x8000) << 16
    let exp = Int((h >> 10) & 0x1F)
    let mant = UInt32(h & 0x3FF)
    let bits: UInt32
    if exp == 0 {
        if mant == 0 { bits = sign } else {
            // Subnormal: normalise it.
            var e = -1
            var m = mant
            repeat { e += 1; m <<= 1 } while m & 0x400 == 0
            bits = sign | UInt32(127 - 15 - e) << 23 | (m & 0x3FF) << 13
        }
    } else if exp == 31 {
        bits = sign | 0x7F80_0000 | (mant << 13)
    } else {
        bits = sign | UInt32(exp - 15 + 127) << 23 | (mant << 13)
    }
    return Float(bitPattern: bits)
}

/// A static-embedding model (Model2Vec "potion"): WordPiece tokens → mean of table rows → normalise.
/// Microseconds per text, pure Swift, works on every Mac.
public final class StaticEmbedder: SentenceEmbedder, @unchecked Sendable {
    public let id: String
    public let dimension: Int
    private let table: [Float]
    private let rows: Int
    private let tokenizer: WordPieceTokenizer

    /// `weights`: raw little-endian float16 (or float32 when `float32` is true), rows × dimension.
    public init(id: String, weights: Data, vocabText: String, dimension: Int, float32: Bool = false) throws {
        self.id = id
        self.dimension = dimension
        tokenizer = WordPieceTokenizer(vocabText: vocabText)
        let bytesPerValue = float32 ? 4 : 2
        guard dimension > 0, weights.count % (dimension * bytesPerValue) == 0 else { throw EmbeddingError.badModelFile("size \(weights.count)") }
        rows = weights.count / (dimension * bytesPerValue)
        var t = [Float](repeating: 0, count: rows * dimension)
        weights.withUnsafeBytes { raw in
            if float32 {
                for i in 0..<t.count { t[i] = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))) }
            } else {
                for i in 0..<t.count { t[i] = halfToFloat(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))) }
            }
        }
        table = t
    }

    public func vector(_ text: String) -> [Float] {
        let ids = tokenizer.ids(text).filter { $0 != tokenizer.unkID && Int($0) < rows }
        var v = [Float](repeating: 0, count: dimension)
        guard !ids.isEmpty else { return v }
        for id in ids {
            let base = Int(id) * dimension
            for j in 0..<dimension { v[j] += table[base + j] }
        }
        let inv = 1 / Float(ids.count)
        for j in 0..<dimension { v[j] *= inv }
        return l2Normalize(v)
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] { texts.map(vector) }
}

/// The tiny-model follower: embeds recent speech, scores it against each point's anchors and keeps a belief.
/// Produces a judge-style verdict after every settled chunk of speech.
public final class TinyFollower: @unchecked Sendable {
    public let embedder: SentenceEmbedder
    public private(set) var tracker: MeaningTracker
    private var scorer: MeaningScorer?
    public private(set) var lastState: MeaningTracker.State?

    public init(embedder: SentenceEmbedder, count: Int, profile: MeaningProfile) {
        self.embedder = embedder
        tracker = MeaningTracker(count: count, profile: profile)
    }

    public var isReady: Bool { scorer != nil }

    /// Embeds each point's anchors (outline text, plus gist and examples when available).
    public func prepare(outline: [OutlineItem], prep: [PointPrep?]?) async throws {
        let anchors = Meaning.anchorTexts(outline, prep: prep)
        let flat = anchors.flatMap { $0 }
        let vecs = try await embedder.embed(flat)
        var k = 0
        scorer = MeaningScorer(anchorVectors: anchors.map { a in a.map { _ in defer { k += 1 }; return vecs[k] } })
    }

    /// Updates the belief from recent speech and returns a verdict relative to the shown point.
    public func observe(chunks: [TimedChunk], now: Double, current: Int) async throws -> JudgeVerdict? {
        guard let scorer else { return nil }
        let short = SpeechWindow.text(chunks, now: now, seconds: 5, minWords: 8, maxWords: 20)
        let long = SpeechWindow.text(chunks, now: now, seconds: 12, minWords: 15, maxWords: 45)
        guard !long.isEmpty else { return nil }
        let v = try await embedder.embed([short.isEmpty ? long : short, long])
        let state = tracker.update(scorer.score(short: v[0], long: v[1]))
        lastState = state
        return tracker.verdict(current: current, state: state)
    }

    /// The user or a judge moved the highlight: start the belief from there.
    public func reset(to point: Int) { tracker.reset(to: point) }

    public var topTwo: [Int] { tracker.topTwo }
}
