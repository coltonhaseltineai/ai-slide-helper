import Foundation

/// A settled piece of recognized speech and when it ended (seconds on any monotonic clock).
public struct TimedChunk: Codable, Equatable, Sendable {
    public var t: Double
    public var text: String
    public init(t: Double, text: String) { self.t = t; self.text = text }
}

public enum SpeechWindow {
    /// Groups recent chunks into lines of at least `minLineWords` words, newest last.
    /// Twin of eval/tools/lib.js speechLines — keep them identical.
    public static func lines(_ chunks: [TimedChunk], now: Double, seconds: Double = 20, minLineWords: Int = 8,
                             maxLines: Int = 12, newestMaxWords: Int = 60) -> [SpeechLine] {
        let recent = chunks.filter { $0.t <= now + 1e-9 && $0.t > now - seconds }
        var lines: [SpeechLine] = []
        var buf: [Substring] = []
        var lastT = 0.0
        for c in recent {
            buf.append(contentsOf: c.text.split(separator: " ", omittingEmptySubsequences: true))
            lastT = c.t
            if buf.count >= minLineWords {
                lines.append(SpeechLine(ago: ago(now, lastT), text: buf.joined(separator: " ")))
                buf = []
            }
        }
        if !buf.isEmpty { lines.append(SpeechLine(ago: ago(now, lastT), text: buf.joined(separator: " "))) }
        var kept = Array(lines.suffix(maxLines))
        if var last = kept.last {
            let w = last.text.split(separator: " ")
            if w.count > newestMaxWords { last.text = w.suffix(newestMaxWords).joined(separator: " "); kept[kept.count - 1] = last }
        }
        return kept
    }

    /// Recent speech as one string: the last `seconds` of words, clamped to [minWords, maxWords].
    /// Twin of eval/tools/meaning.js windowText.
    public static func text(_ chunks: [TimedChunk], now: Double, seconds: Double, minWords: Int, maxWords: Int) -> String {
        var ws: [Substring] = []
        for c in chunks.reversed() {
            if c.t <= now - 60 { break }
            if c.t > now + 1e-9 { continue }
            if c.t < now - seconds && ws.count >= minWords { break }
            ws = c.text.split(separator: " ", omittingEmptySubsequences: true) + ws
            if ws.count >= maxWords { break }
        }
        return ws.suffix(maxWords).joined(separator: " ")
    }

    // JS Math.round rounds halves up; Swift's default rounds halves away from zero. Same for ago >= 0.
    private static func ago(_ now: Double, _ t: Double) -> Int { max(0, Int((now - t).rounded(.toNearestOrAwayFromZero))) }
}
