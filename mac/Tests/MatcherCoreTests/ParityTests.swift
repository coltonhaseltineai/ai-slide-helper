import XCTest
@testable import MatcherCore

/// Replays fixtures produced by the JavaScript reference (eval/tools/fixtures.js, api/_judge-render.js,
/// and the Python tokenizers package) so the Mac app behaves exactly like what the benchmark measured.
final class ParityTests: XCTestCase {
    func fixture(_ name: String) throws -> Any {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    }

    func items(_ raw: Any?) -> [OutlineItem] {
        ((raw as? [[String: Any]]) ?? []).enumerated().map { i, d in
            OutlineItem(id: i, text: d["text"] as? String ?? "", cues: d["cues"] as? [String] ?? [], level: d["level"] as? Int ?? 0)
        }
    }

    func lines(_ raw: Any?) -> [SpeechLine] {
        ((raw as? [[String: Any]]) ?? []).map { SpeechLine(ago: $0["ago"] as? Int ?? 0, text: $0["text"] as? String ?? "") }
    }

    func testPromptMatchesServerByteForByte() throws {
        let root = try XCTUnwrap(fixture("prompts.json") as? [String: Any])
        let setData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(root["promptSet"]))
        let set = try JSONDecoder().decode(JudgePrompt.PromptSet.self, from: setData)
        XCTAssertNotNil(set.currentVariant)
        for (n, c) in try XCTUnwrap(root["cases"] as? [[String: Any]]).enumerated() {
            let input = try XCTUnwrap(c["input"] as? [String: Any])
            let r = JudgePrompt.render(JudgeInput(outline: items(input["items"]), current: input["current"] as? Int ?? 0,
                                                  lines: lines(input["lines"]), gists: input["gists"] as? [String]))
            XCTAssertEqual(r.outlineBlock, c["outlineBlock"] as? String, "case \(n) outline")
            XCTAssertEqual(r.dynamicBlock, c["dynamicBlock"] as? String, "case \(n) speech")
            XCTAssertEqual(r.prompt, c["prompt"] as? String, "case \(n) prompt")
            XCTAssertEqual(r.visible, (c["visibleStart"] as? Int ?? -1)..<(c["visibleEnd"] as? Int ?? -1), "case \(n) visible")
        }
    }

    func testSpeechWindowsMatch() throws {
        let root = try XCTUnwrap(fixture("speech-windows.json") as? [String: Any])
        let chunks = ((root["chunks"] as? [[String: Any]]) ?? []).map { TimedChunk(t: $0["t"] as? Double ?? 0, text: $0["text"] as? String ?? "") }
        for c in try XCTUnwrap(root["cases"] as? [[String: Any]]) {
            let now = c["now"] as? Double ?? 0
            XCTAssertEqual(SpeechWindow.lines(chunks, now: now), lines(c["lines"]), "lines at \(now)")
            XCTAssertEqual(SpeechWindow.text(chunks, now: now, seconds: 5, minWords: 8, maxWords: 20), c["short"] as? String, "short at \(now)")
            XCTAssertEqual(SpeechWindow.text(chunks, now: now, seconds: 12, minWords: 15, maxWords: 45), c["long"] as? String, "long at \(now)")
        }
    }

    func testFollowerMatchesReference() throws {
        let root = try XCTUnwrap(fixture("follower-script.json") as? [String: Any])
        var f = Follower(count: root["count"] as? Int ?? 0, policy: .live)
        for (n, e) in try XCTUnwrap(root["events"] as? [[String: Any]]).enumerated() {
            let at = e["at"] as? Double ?? 0
            switch e["kind"] as? String {
            case "manual":
                f.manual(e["point"] as? Int ?? 0, at: at)
            case "keyword":
                XCTAssertEqual(f.keyword(e["point"] as? Int ?? 0, at: at), e["moved"] as? Bool, "event \(n)")
            default:
                let v = try XCTUnwrap(e["verdict"] as? [String: Any])
                let verdict = JudgeVerdict(state: JudgeState(rawValue: v["state"] as? String ?? "") ?? .unclear,
                                           point: v["point"] as? Int ?? 0,
                                           confidence: JudgeConfidence(rawValue: v["confidence"] as? String ?? "") ?? .low)
                let d = f.verdict(verdict, seq: e["seq"] as? Int ?? 0, askedAt: e["askedAt"] as? Double ?? 0,
                                  askedCurrent: e["askedCurrent"] as? Int ?? 0, at: at,
                                  localSupport: e["localSupport"] as? Bool ?? false, source: e["source"] as? String ?? "judge")
                XCTAssertEqual(d.didMove, e["moved"] as? Bool, "event \(n)")
                if case .held(let reason) = d { XCTAssertEqual(reason, e["reason"] as? String, "event \(n) reason") }
            }
            XCTAssertEqual(f.current, e["current"] as? Int, "event \(n) current")
        }
        for s in try XCTUnwrap(root["schedule"] as? [[String: Any]]) {
            let args = (now: s["now"] as? Double ?? 0, last: s["lastAskAt"] as? Double ?? 0, word: s["lastWordAt"] as? Double ?? 0,
                        words: s["newWords"] as? Int ?? 0, inFlight: s["inFlight"] as? Bool ?? false)
            XCTAssertEqual(shouldJudge(now: args.now, lastAskAt: args.last, lastWordAt: args.word, newWords: args.words, inFlight: args.inFlight, cadence: .onDevice), s["onDevice"] as? Bool)
            XCTAssertEqual(shouldJudge(now: args.now, lastAskAt: args.last, lastWordAt: args.word, newWords: args.words, inFlight: args.inFlight, cadence: .claude), s["claude"] as? Bool)
        }
    }

    func testMeaningTrackerMatchesReference() throws {
        let root = try XCTUnwrap(fixture("meaning-script.json") as? [String: Any])
        let profile = try JSONDecoder().decode(MeaningProfile.self, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(root["profile"])))
        var tracker = MeaningTracker(count: root["count"] as? Int ?? 0, profile: profile)
        var current = 0
        for (n, s) in try XCTUnwrap(root["steps"] as? [[String: Any]]).enumerated() {
            let scores = MeaningScorer.Scores(short: s["zs"] as? [Double] ?? [], long: s["zl"] as? [Double] ?? [], maxLong: s["maxLong"] as? Double ?? 0)
            let st = tracker.update(scores)
            XCTAssertEqual(st.best, s["best"] as? Int, "step \(n) best")
            XCTAssertEqual(st.tangent, s["tangent"] as? Bool, "step \(n) tangent")
            for (a, b) in zip(tracker.belief, s["belief"] as? [Double] ?? []) { XCTAssertEqual(a, b, accuracy: 1e-9, "step \(n) belief") }
            let v = tracker.verdict(current: current, state: st)
            let expected = try XCTUnwrap(s["verdict"] as? [String: Any])
            XCTAssertEqual(v.state.rawValue, expected["state"] as? String, "step \(n) verdict")
            XCTAssertEqual(v.point, expected["point"] as? Int, "step \(n) point")
            XCTAssertEqual(v.confidence.rawValue, expected["confidence"] as? String, "step \(n) confidence")
            if v.state == .moved { current = v.point }
        }
        let a = try XCTUnwrap(root["anchors"] as? [String: Any])
        let prep: [PointPrep?] = ((a["prep"] as? [Any]) ?? []).map { p in
            guard let d = p as? [String: Any] else { return nil }
            return PointPrep(gist: d["gist"] as? String ?? "", examples: d["examples"] as? [String] ?? [])
        }
        XCTAssertEqual(Meaning.anchorTexts(items(a["items"]), prep: prep), a["expected"] as? [[String]])
    }

    func testWordPieceMatchesHuggingFace() throws {
        let vocabURL = try XCTUnwrap(Bundle.module.url(forResource: "bert-uncased-vocab.txt", withExtension: nil, subdirectory: "Fixtures"))
        let tok = WordPieceTokenizer(vocabText: try String(contentsOf: vocabURL, encoding: .utf8))
        let root = try XCTUnwrap(fixture("wordpiece-golden.json") as? [String: Any])
        for c in try XCTUnwrap(root["cases"] as? [[String: Any]]) {
            let text = c["text"] as? String ?? ""
            XCTAssertEqual(tok.tokenize(text), c["tokens"] as? [String], "tokens for \(text.debugDescription)")
            XCTAssertEqual(tok.ids(text).map(Int.init), c["ids"] as? [Int], "ids for \(text.debugDescription)")
        }
        let enc = tok.encode("hello world", maxLength: 3)
        XCTAssertEqual(enc.ids.count, 3)
        XCTAssertEqual(enc.ids.first, tok.clsID)
        XCTAssertEqual(enc.ids.last, tok.sepID)
    }
}

final class DeadlineAndPromptTests: XCTestCase {
    func testDeadlineReturnsEvenIfWorkIgnoresCancellation() async {
        let start = Date()
        do {
            _ = try await withDeadline(0.3) { () -> Int in
                // Busy work that never checks for cancellation.
                let until = Date().addingTimeInterval(2)
                while Date() < until { usleep(10_000) }
                return 1
            }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? JudgeFailure, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.8)
    }

    func testDeadlinePassesResultsAndErrorsThrough() async throws {
        let v = try await withDeadline(2) { 42 }
        XCTAssertEqual(v, 42)
        do {
            _ = try await withDeadline(2) { () -> Int in throw JudgeFailure.guardrail }
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? JudgeFailure, .guardrail) }
    }

    func testParseLineAndValidate() {
        XCTAssertEqual(JudgePrompt.parseLine("moved 4 high", visible: 0..<6, current: 2), JudgeVerdict(state: .moved, point: 3, confidence: .high))
        XCTAssertEqual(JudgePrompt.parseLine("Same.", visible: 0..<6, current: 2), JudgeVerdict(state: .same, point: 2, confidence: .low))
        XCTAssertEqual(JudgePrompt.parseLine("moved 9 medium", visible: 0..<6, current: 2)?.state, .unclear)
        XCTAssertNil(JudgePrompt.parseLine("no idea", visible: 0..<6, current: 2))
        XCTAssertEqual(JudgePrompt.validate(JudgeVerdict(state: .same, point: 5, confidence: .high), visible: 0..<6, current: 1).point, 1)
    }

    func testConfidenceOrdering() {
        XCTAssertLessThan(JudgeConfidence.low, .medium)
        XCTAssertLessThan(JudgeConfidence.medium, .high)
    }
}
