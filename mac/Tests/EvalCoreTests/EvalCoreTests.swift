import XCTest
@testable import EvalCore
import MatcherCore

/// Checks the Swift benchmark engine against the JavaScript reference (eval/run.js) on the same talks.
final class EvalCoreTests: XCTestCase {
    /// Repository root, found from this file's location (tests run from a checkout).
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    func talk(_ id: String) throws -> BuiltTalk {
        try BuiltTalk.load(Self.repo.appendingPathComponent("eval/built/\(id).json"))
    }

    func reference() throws -> [[String: Any]] {
        let url = Self.repo.appendingPathComponent("mac/Tests/MatcherCoreTests/Fixtures/closed-loop.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(root["runs"] as? [[String: Any]])
    }

    /// Same scripted judge as eval/tools/fixtures.js: answers from a hash of the newest speech line.
    static func scripted(_ input: JudgeInput) -> JudgeVerdict {
        let newest = input.lines.last?.text ?? ""
        var h = 0
        for u in newest.unicodeScalars { h = (h * 31 + Int(u.value)) % 1_000_003 }
        let states: [JudgeState] = [.same, .moved, .moved, .tangent, .unclear, .moved, .same]
        let state = states[h % states.count]
        let confs: [JudgeConfidence] = [.low, .medium, .high, .high]
        let step = [1, 1, 1, 2, -1][h % 5]
        let point = state == .moved ? max(0, min(input.outline.count - 1, input.current + step)) : input.current
        return JudgeVerdict(state: state, point: point, confidence: confs[(h >> 3) % confs.count])
    }

    func moves(_ raw: Any?) -> [Move] {
        ((raw as? [[String: Any]]) ?? []).map { Move(t: $0["t"] as? Double ?? -1, to: $0["to"] as? Int ?? -1) }
    }

    @MainActor
    func testClosedLoopMatchesJavaScript() async throws {
        for ref in try reference() {
            let id = try XCTUnwrap(ref["talk"] as? String)
            let t = try talk(id)
            let judge = ScriptedJudge(latencyMs: 1200, answer: Self.scripted)
            let run = await runClosedLoop(t, judge: judge, tiny: nil, cadence: .claude)
            let expected = moves(ref["moves"])
            XCTAssertEqual(run.moves.count, expected.count, "\(id) move count")
            for (a, b) in zip(run.moves, expected) {
                XCTAssertEqual(a.to, b.to, "\(id) move target")
                XCTAssertEqual(a.t, b.t, accuracy: 1e-6, "\(id) move time")
            }
            XCTAssertEqual(run.calls, ref["calls"] as? Int, "\(id) calls")
            let s = try XCTUnwrap(ref["score"] as? [String: Any])
            XCTAssertEqual(run.score.onCorrect, s["onCorrect"] as? Double ?? -1, accuracy: 1e-9, "\(id) onCorrect")
            XCTAssertEqual(run.score.missed, s["missed"] as? Int, "\(id) missed")
            XCTAssertEqual(run.score.wrongMoves, s["wrongMoves"] as? Int, "\(id) wrong")
            XCTAssertEqual(run.score.flicker, s["flicker"] as? Int, "\(id) flicker")
            let lags = s["lags"] as? [Double] ?? []
            XCTAssertEqual(run.score.lags.count, lags.count, "\(id) lags")
            for (a, b) in zip(run.score.lags, lags) { XCTAssertEqual(a, b, accuracy: 1e-6) }

            let kw = runKeywords(t)
            let kwExpected = moves(ref["keywordMoves"])
            XCTAssertEqual(kw.moves.map(\.to), kwExpected.map(\.to), "\(id) keyword moves")
            let ks = try XCTUnwrap(ref["keywordScore"] as? [String: Any])
            XCTAssertEqual(kw.score.onCorrect, ks["onCorrect"] as? Double ?? -1, accuracy: 1e-9, "\(id) keyword onCorrect")
        }
    }

    func testOracleIsNearPerfectAndScoringBasics() throws {
        let t = try talk("sleep")
        let oracle = runOracle(t)
        XCTAssertGreaterThan(oracle.score.onCorrect, 0.97)
        XCTAssertEqual(oracle.score.missed, 0)
        XCTAssertEqual(oracle.score.wrongMoves, 0)
        let none = scoreTimeline(t, moves: [])
        XCTAssertLessThan(none.onCorrect, 0.3)
        XCTAssertEqual(none.missed, none.switches)
        let s = summarize("oracle", [oracle])
        XCTAssertEqual(s.missed, 0)
        XCTAssertEqual(s.perTalk["sleep"], (100 * oracle.score.onCorrect).rounded())
    }

    @MainActor
    func testSlowerJudgeLagsMore() async throws {
        let t = try talk("sleep")
        // A perfect judge that knows the truth, answering fast vs slow (virtual time, no sleeping).
        @MainActor func perfect(_ ms: Int) -> ScriptedJudge {
            ScriptedJudge(latencyMs: ms) { input in
                JudgeVerdict(state: .moved, point: min(input.current + 1, input.outline.count - 1), confidence: .high)
            }
        }
        let fast = await runClosedLoop(t, judge: perfect(100), tiny: nil, cadence: .onDevice)
        let slow = await runClosedLoop(t, judge: perfect(2400), tiny: nil, cadence: .onDevice)
        XCTAssertGreaterThanOrEqual(slow.latencies.min() ?? 0, 2.39)
        XCTAssertLessThan(fast.latencies.max() ?? 1, 0.2)
        XCTAssertNotEqual(fast.moves.first?.t, slow.moves.first?.t)
    }
}
