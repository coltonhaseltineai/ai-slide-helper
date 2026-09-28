import Foundation

/// BERT "uncased" tokenizer: clean text, split CJK characters, lowercase, strip accents, split on
/// whitespace and punctuation, then greedy longest-match WordPiece with "##" continuations.
/// Matches Hugging Face's BertWordPieceTokenizer (checked against golden token ids in the tests).
public struct WordPieceTokenizer: Sendable {
    public let vocab: [String: Int32]
    public let unkID: Int32
    public let clsID: Int32?
    public let sepID: Int32?
    public let maxCharsPerWord = 100

    /// `vocabText`: the contents of vocab.txt, one token per line; line number = id.
    public init(vocabText: String) {
        var v: [String: Int32] = [:]
        var i: Int32 = 0
        vocabText.enumerateLines { line, _ in
            if v[line] == nil { v[line] = i }
            i += 1
        }
        vocab = v
        unkID = v["[UNK]"] ?? 100
        clsID = v["[CLS]"]
        sepID = v["[SEP]"]
    }

    /// Word pieces for `text` (no special tokens).
    public func tokenize(_ text: String) -> [String] {
        var out: [String] = []
        for word in basicTokens(text) {
            let chars = Array(word.unicodeScalars)
            if chars.count > maxCharsPerWord { out.append("[UNK]"); continue }
            var pieces: [String] = []
            var start = 0
            var bad = false
            while start < chars.count {
                var end = chars.count
                var found: String?
                while start < end {
                    var sub = String(String.UnicodeScalarView(chars[start..<end]))
                    if start > 0 { sub = "##" + sub }
                    if vocab[sub] != nil { found = sub; break }
                    end -= 1
                }
                guard let piece = found else { bad = true; break }
                pieces.append(piece)
                start = end
            }
            if bad { out.append("[UNK]") } else { out.append(contentsOf: pieces) }
        }
        return out
    }

    public func ids(_ text: String) -> [Int32] { tokenize(text).map { vocab[$0] ?? unkID } }

    /// Model input: [CLS] ids [SEP], truncated to `maxLength`, and an attention mask.
    public func encode(_ text: String, maxLength: Int = 128) -> (ids: [Int32], mask: [Int32]) {
        var body = ids(text)
        let specials = (clsID != nil ? 1 : 0) + (sepID != nil ? 1 : 0)
        if body.count > maxLength - specials { body = Array(body.prefix(maxLength - specials)) }
        var ids: [Int32] = []
        if let c = clsID { ids.append(c) }
        ids += body
        if let s = sepID { ids.append(s) }
        return (ids, Array(repeating: 1, count: ids.count))
    }

    // MARK: - Basic tokenizer

    func basicTokens(_ text: String) -> [String] {
        // 1. Clean: drop NUL/replacement/control characters, map whitespace to a space, pad CJK characters.
        var cleaned = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            if u.value == 0 || u.value == 0xFFFD || Self.isControl(u) { continue }
            if Self.isWhitespace(u) { cleaned.append(" "); continue }
            if Self.isCJK(u) { cleaned.append(" "); cleaned.append(u); cleaned.append(" "); continue }
            cleaned.append(u)
        }
        var tokens: [String] = []
        for raw in String(cleaned).split(separator: " ", omittingEmptySubsequences: true) {
            // 2. Lowercase and strip accents (NFD, then drop combining marks).
            let lowered = raw.lowercased().decomposedStringWithCanonicalMapping
            var stripped = String.UnicodeScalarView()
            for u in lowered.unicodeScalars where u.properties.generalCategory != .nonspacingMark { stripped.append(u) }
            // 3. Split punctuation into its own tokens.
            var current = String.UnicodeScalarView()
            for u in stripped {
                if Self.isPunctuation(u) {
                    if !current.isEmpty { tokens.append(String(current)); current = String.UnicodeScalarView() }
                    tokens.append(String(u))
                } else {
                    current.append(u)
                }
            }
            if !current.isEmpty { tokens.append(String(current)) }
        }
        return tokens
    }

    static func isWhitespace(_ u: Unicode.Scalar) -> Bool {
        if u == " " || u == "\t" || u == "\n" || u == "\r" { return true }
        return u.properties.generalCategory == .spaceSeparator
    }

    static func isControl(_ u: Unicode.Scalar) -> Bool {
        if u == "\t" || u == "\n" || u == "\r" { return false }
        switch u.properties.generalCategory {
        case .control, .format: return true
        default: return false
        }
    }

    static func isPunctuation(_ u: Unicode.Scalar) -> Bool {
        let c = u.value
        if (33...47).contains(c) || (58...64).contains(c) || (91...96).contains(c) || (123...126).contains(c) { return true }
        switch u.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation: return true
        default: return false
        }
    }

    static func isCJK(_ u: Unicode.Scalar) -> Bool {
        let c = u.value
        return (0x4E00...0x9FFF).contains(c) || (0x3400...0x4DBF).contains(c) || (0x20000...0x2A6DF).contains(c)
            || (0x2A700...0x2B73F).contains(c) || (0x2B740...0x2B81F).contains(c) || (0x2B820...0x2CEAF).contains(c)
            || (0xF900...0xFAFF).contains(c) || (0x2F800...0x2FA1F).contains(c)
    }
}
