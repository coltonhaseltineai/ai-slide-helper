import Foundation

/// The judge prompt, byte-for-byte the same as the server's api/_judge-render.js (checked by shared fixtures),
/// so Apple's on-device model and Claude see exactly the same question.
public enum JudgePrompt {
    public static let maxVisible = 24

    /// The prompt variants file (api/_judge-prompt.json, bundled into the app).
    public struct PromptSet: Codable, Sendable {
        public struct Variant: Codable, Sendable {
            public var rules: String
            public var prepRules: String
        }
        public var current: String
        public var variants: [String: Variant]

        public var currentVariant: Variant? { variants[current] }
    }

    public struct Rendered: Equatable, Sendable {
        public var outlineBlock: String
        public var dynamicBlock: String
        public var prompt: String
        /// Which points (0-based, half-open) the prompt shows.
        public var visible: Range<Int>
    }

    /// Collapses runs of ASCII whitespace to one space and trims them (same as JS /[ \t\r\n]+/).
    public static func squash(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for u in s.unicodeScalars {
            if u == " " || u == "\t" || u == "\r" || u == "\n" {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" "); pendingSpace = false }
                out.append(u)
            }
        }
        return String(out)
    }

    /// The first `n` Unicode scalars (same as JS Array.from(s).slice(0, n)).
    public static func clip(_ s: String, _ n: Int) -> String {
        let u = s.unicodeScalars
        guard u.count > n else { return s }
        return String(String.UnicodeScalarView(u.prefix(n)))
    }

    public static func visibleRange(count: Int, current: Int) -> Range<Int> {
        guard count > maxVisible else { return 0..<count }
        let start = min(max(current - 6, 0), count - maxVisible)
        return start..<(start + maxVisible)
    }

    public static func outlineBlock(_ items: [OutlineItem], current: Int, gists: [String]?) -> (text: String, visible: Range<Int>) {
        let visible = visibleRange(count: items.count, current: current)
        var lines: [String] = []
        for i in visible {
            let it = items[i]
            var line = String(repeating: "   ", count: min(max(it.level, 0), 3)) + String(i + 1) + ". " + clip(squash(it.text), 120)
            let cues = it.cues.map(squash).filter { !$0.isEmpty }
            if !cues.isEmpty { line += " [also: " + cues.joined(separator: ", ") + "]" }
            if let gists, i < gists.count, !gists[i].isEmpty { line += " — " + clip(squash(gists[i]), 120) }
            lines.append(line)
        }
        let note = (visible.lowerBound > 0 || visible.upperBound < items.count)
            ? "(Only points \(visible.lowerBound + 1)-\(visible.upperBound) of \(items.count) are shown.)\n" : ""
        return ("Outline:\n" + note + lines.joined(separator: "\n"), visible)
    }

    public static func dynamicBlock(current: Int, lines: [SpeechLine]) -> String {
        var out = "Shown now: point \(current + 1).\nSpeech, oldest first:\n"
        guard !lines.isEmpty else { return out + "(no speech yet)" }
        out += lines.enumerated().map { i, l in
            (i == lines.count - 1 ? "[newest] " : "[\(l.ago)s ago] ") + squash(l.text)
        }.joined(separator: "\n")
        return out
    }

    public static func render(_ input: JudgeInput) -> Rendered {
        let o = outlineBlock(input.outline, current: input.current, gists: input.gists)
        let d = dynamicBlock(current: input.current, lines: input.lines)
        return Rendered(outlineBlock: o.text, dynamicBlock: d, prompt: o.text + "\n\n" + d, visible: o.visible)
    }

    /// Prompt asking for a gist and example sentences per point (outline only, never speech).
    public static func renderPrep(_ items: [OutlineItem]) -> String {
        let lines = items.enumerated().map { i, it -> String in
            var line = String(repeating: "   ", count: min(max(it.level, 0), 3)) + String(i + 1) + ". " + clip(squash(it.text), 120)
            if !it.cues.isEmpty { line += " [also: " + it.cues.map(squash).joined(separator: ", ") + "]" }
            return line
        }
        return "Outline:\n" + lines.joined(separator: "\n") + "\n\nWrite \(items.count) entries, one per point, in order."
    }

    /// Checks a verdict against what the prompt showed: an unknown point means "unclear".
    public static func validate(_ v: JudgeVerdict, visible: Range<Int>, current: Int) -> JudgeVerdict {
        guard visible.contains(v.point) else { return JudgeVerdict(state: .unclear, point: current, confidence: v.confidence) }
        if v.state != .moved { return JudgeVerdict(state: v.state, point: current, confidence: v.confidence) }
        return v
    }

    /// Parses a plain-text answer like "moved 4 high" (1-based point), used when structured output isn't available.
    public static func parseLine(_ text: String, visible: Range<Int>, current: Int) -> JudgeVerdict? {
        let parts = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard let state = parts.lazy.compactMap({ JudgeState(rawValue: $0) }).first else { return nil }
        let number = parts.lazy.compactMap { Int($0) }.first
        let confidence = parts.lazy.compactMap { JudgeConfidence(rawValue: $0) }.first ?? .low
        let point = number.map { $0 - 1 } ?? current
        return validate(JudgeVerdict(state: state, point: point, confidence: confidence), visible: visible, current: current)
    }
}
