import AppKit
import EvalCore
import MatcherCore
import SwiftUI

/// Help → Compare Judges: replays the benchmark talks through each way of following, on this Mac,
/// and puts Apple's on-device model and the tiny model next to Claude's recorded results.
@MainActor
@Observable
final class CompareModel {
    enum Preset: String, CaseIterable, Identifiable {
        case quick, full, soak
        var id: String { rawValue }
        var title: String {
            switch self {
            case .quick: return "Quick (about 10 min)"
            case .full: return "Full (about 40 min)"
            case .soak: return "Background soak (30 min)"
            }
        }
        var detail: String {
            switch self {
            case .quick: return "3 talks. Enough to see if Apple's model keeps up with Claude."
            case .full: return "All 10 talks. The numbers used to pick the default."
            case .soak: return "Apple's model only, over and over for 30 minutes. Put Keynote (or any app) in front while it runs: this catches slow-downs when Live Outline is in the background."
            }
        }
    }

    enum Contender: String, CaseIterable, Identifiable, Codable {
        case keywords, tinyBare, tinyPrep, onDevice, claudeHaiku, claudeSonnet, oracle
        var id: String { rawValue }
        var title: String {
            switch self {
            case .keywords: return "Keywords"
            case .tinyBare: return "Tiny model (outline only)"
            case .tinyPrep: return "Tiny model + Apple-written examples"
            case .onDevice: return "Apple on-device model"
            case .claudeHaiku: return "Claude Haiku (recorded)"
            case .claudeSonnet: return "Claude Sonnet (recorded)"
            case .oracle: return "Perfect follower (ceiling)"
            }
        }
        var needsAppleModel: Bool { self == .tinyPrep || self == .onDevice }
    }

    struct Row: Identifiable, Codable {
        var id: String { contender.rawValue }
        var contender: Contender
        var summary: Summary
    }

    var preset: Preset = .quick
    var chosen: Set<Contender> = Set(Contender.allCases)
    private(set) var running = false
    private(set) var progress = 0.0
    private(set) var step = ""
    private(set) var rows: [Row] = []
    private(set) var notes: [String] = []
    private(set) var diagnostics: [String: String] = [:]
    private(set) var prepSeconds: [Double] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runs: [Contender: [TalkRun]] = [:]

    var hasResults: Bool { !rows.isEmpty }

    func refreshDiagnostics(accessCode: String) {
        let pi = ProcessInfo.processInfo
        let fm = OnDevice.status()
        var d: [String: String] = [
            "app": SmartClient.appVersion,
            "macOS": pi.operatingSystemVersionString,
            "chip": Self.chip(),
            "memoryGB": String(pi.physicalMemory / 1_073_741_824),
            "onDevice": fm.code,
            "thermal": ["nominal", "fair", "serious", "critical"][min(pi.thermalState.rawValue, 3)],
            "lowPowerMode": pi.isLowPowerModeEnabled ? "on" : "off",
            "promptVersion": AppResources.promptSet?.current ?? "missing",
            "tinyModel": ModelStore.shared.state == .ready ? "ready" : "not downloaded",
        ]
        if let n = OnDevice.contextSize() { d["contextTokens"] = String(n) }
        diagnostics = d
        guard !accessCode.isEmpty else { return }
        Task {
            if let r = try? await SmartClient(accessCode: accessCode).ping() {
                diagnostics["server"] = "\(r.promptVersion ?? "?") in \(String(format: "%.2f", r.seconds)) s"
            } else {
                diagnostics["server"] = "unreachable"
            }
        }
    }

    static func chip() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    func start(accessCode: String) {
        guard !running else { return }
        running = true
        rows = []; notes = []; runs = [:]; prepSeconds = []; progress = 0
        refreshDiagnostics(accessCode: accessCode)
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Comparing judges")
        task = Task {
            await run()
            ProcessInfo.processInfo.endActivity(activity)
            running = false
            step = Task.isCancelled ? "Stopped" : "Done"
        }
    }

    func stop() { task?.cancel() }

    private func talkIDs() -> [String] {
        let s = AppResources.splits
        switch preset {
        case .quick: return Array(s.test.prefix(3))
        case .full: return s.dev + s.test
        case .soak: return s.test
        }
    }

    private func run() async {
        let talks = talkIDs().compactMap { id in AppResources.talkURL(id).flatMap { try? BuiltTalk.load($0) } }
        guard !talks.isEmpty else { notes.append("The benchmark talks are missing from this build."); return }
        let fmReady = OnDevice.status().isReady
        var contenders = Contender.allCases.filter { chosen.contains($0) }
        if preset == .soak { contenders = [.onDevice] }
        if !fmReady, contenders.contains(where: \.needsAppleModel) {
            notes.append("Apple's on-device model isn't available (\(OnDevice.status().label)), so its rows are skipped.")
            contenders.removeAll(where: \.needsAppleModel)
        }
        if contenders.contains(where: { $0 == .tinyBare || $0 == .tinyPrep }) {
            step = "Getting the tiny model…"
            await ModelStore.shared.ensure()
            if ModelStore.shared.embedder == nil {
                notes.append("The tiny model couldn't be downloaded, so its rows are skipped.")
                contenders.removeAll { $0 == .tinyBare || $0 == .tinyPrep }
            }
        }
        let reference = ClaudeReference.load()
        if reference == nil, contenders.contains(where: { $0 == .claudeHaiku || $0 == .claudeSonnet }) {
            notes.append("Recorded Claude results are missing from this build.")
        }

        let soakUntil = Date().addingTimeInterval(30 * 60)
        repeat {
            for (ti, talk) in talks.enumerated() {
                for (ci, c) in contenders.enumerated() {
                    if Task.isCancelled { return }
                    let base = preset == .soak ? min(1, Date().timeIntervalSince(soakUntil.addingTimeInterval(-30 * 60)) / (30 * 60))
                        : (Double(ti) + Double(ci) / Double(contenders.count)) / Double(talks.count)
                    step = "\(talk.title): \(c.title)"
                    progress = base
                    if let r = await runOne(c, talk, reference: reference, progress: { [weak self] p in
                        guard let self, self.preset != .soak else { return }
                        self.progress = base + p / Double(contenders.count * talks.count)
                    }) {
                        runs[c, default: []].append(r)
                        publish()
                    }
                }
            }
        } while preset == .soak && Date() < soakUntil && !Task.isCancelled
        progress = 1
    }

    private func runOne(_ c: Contender, _ talk: BuiltTalk, reference: ClaudeReference?, progress: @escaping (Double) -> Void) async -> TalkRun? {
        switch c {
        case .keywords: return runKeywords(talk)
        case .oracle: return runOracle(talk)
        case .claudeHaiku: return reference?.run("haiku", talk)
        case .claudeSonnet: return reference?.run("sonnet", talk)
        case .onDevice:
            guard let judge = OnDevice.makeJudge(rules: AppResources.judgeRules) else { return nil }
            await judge.prepare(outline: talk.outline, gists: nil)
            return await runClosedLoop(talk, judge: judge, tiny: nil, cadence: .onDevice, progress: progress)
        case .tinyBare, .tinyPrep:
            guard let embedder = ModelStore.shared.embedder else { return nil }
            var prep: [PointPrep]?
            if c == .tinyPrep {
                let started = Date()
                do {
                    prep = try await OnDevice.writePrep(outline: talk.outline, rules: AppResources.prepRules)
                    prepSeconds.append(Date().timeIntervalSince(started))
                } catch {
                    notes.append("Apple's model couldn't write examples for “\(talk.title)”: \((error as? JudgeFailure)?.kind ?? "error").")
                    return nil
                }
            }
            let key = "\(ModelStore.profileKey):\(prep == nil ? "bare" : "prep")"
            let tiny = TinyFollower(embedder: embedder, count: talk.outline.count, profile: AppResources.profile(key))
            do { try await tiny.prepare(outline: talk.outline, prep: prep) } catch { return nil }
            return await runClosedLoop(talk, judge: nil, tiny: tiny, cadence: .onDevice, progress: progress)
        }
    }

    private func publish() {
        rows = Contender.allCases.compactMap { c in
            guard let r = runs[c], !r.isEmpty else { return nil }
            return Row(contender: c, summary: summarize(c.rawValue, r))
        }
    }

    /// Everything needed to decide the default, and no speech text.
    func resultsJSON() -> String {
        struct Out: Encodable {
            var preset: String
            var talks: [String]
            var diagnostics: [String: String]
            var rows: [Row]
            var prepSeconds: [Double]
            var notes: [String]
        }
        let out = Out(preset: preset.rawValue, talks: Array(Set(runs.values.flatMap { $0.map(\.talk) })).sorted(),
                      diagnostics: diagnostics, rows: rows, prepSeconds: prepSeconds.map { ($0 * 10).rounded() / 10 }, notes: notes)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "n/a")
        return (try? enc.encode(out)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// Claude's answers on the same talks, recorded by eval/run.js (answered on a Claude subscription;
/// latency is the median measured earlier on the API). Re-scored here with the app's own scorer.
struct ClaudeReference: Decodable {
    struct TalkRecord: Decodable {
        var moves: [Move]
        var calls: Int
        var latencies: [Double]
        var errors: Int
    }
    var note: String?
    var contenders: [String: [String: TalkRecord]]

    static func load() -> ClaudeReference? {
        AppResources.data("claude-reference.json").flatMap { try? JSONDecoder().decode(ClaudeReference.self, from: $0) }
    }

    func run(_ model: String, _ talk: BuiltTalk) -> TalkRun? {
        guard let r = contenders[model]?[talk.id] else { return nil }
        return TalkRun(talk: talk.id, moves: r.moves, calls: r.calls, latencies: r.latencies,
                       errors: Array(repeating: "error", count: r.errors), score: scoreTimeline(talk, moves: r.moves))
    }
}

struct CompareView: View {
    @Environment(AppModel.self) private var app
    @State private var model = CompareModel()
    @State private var copied = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            Text("Compare Judges").font(.title2.weight(.semibold))
            Text("Replays practice talks, where the speaker rarely uses the outline's words, through each way of following. Nothing leaves your Mac except the optional server check.")
                .font(.callout).foregroundStyle(.secondary)

            GroupBox("This Mac") {
                let keys = ["chip", "macOS", "memoryGB", "onDevice", "contextTokens", "thermal", "lowPowerMode", "tinyModel", "server", "promptVersion"]
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(keys.filter { model.diagnostics[$0] != nil }, id: \.self) { k in
                        GridRow {
                            Text(k).foregroundStyle(.secondary)
                            Text(model.diagnostics[k] ?? "").textSelection(.enabled)
                        }
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Test", selection: $model.preset) {
                        ForEach(CompareModel.Preset.allCases) { Text($0.title).tag($0) }
                    }
                    .frame(maxWidth: 320)
                    Text(model.preset.detail).font(.caption).foregroundStyle(.secondary).frame(maxWidth: 320, alignment: .leading)
                }
                if model.preset != .soak {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(CompareModel.Contender.allCases) { c in
                            Toggle(c.title, isOn: Binding(
                                get: { model.chosen.contains(c) },
                                set: { on in if on { model.chosen.formUnion([c]) } else { model.chosen.subtract([c]) } }))
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .disabled(model.running)

            HStack {
                Button(model.running ? "Stop" : "Start") {
                    if model.running { model.stop() } else { model.start(accessCode: app.accessCode) }
                }
                .keyboardShortcut(.defaultAction)
                if model.running || model.progress > 0 {
                    ProgressView(value: model.progress).frame(maxWidth: 240)
                    Text(model.step).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(copied ? "Copied" : "Copy Results as JSON") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.resultsJSON(), forType: .string)
                    copied = true
                }
                .disabled(!model.hasResults)
            }

            Table(model.rows) {
                TableColumn("Judge") { r in Text(r.contender.title) }.width(min: 200)
                TableColumn("On the right point") { r in Text(pct(r.summary.onCorrect)) }
                TableColumn("Catch-up (typical / slow)") { r in Text("\(sec(r.summary.lagP50)) / \(sec(r.summary.lagP90))") }
                TableColumn("Missed switches") { r in Text("\(r.summary.missed) of \(r.summary.switches)") }
                TableColumn("Wrong jumps / 10 min") { r in Text(num(r.summary.wrongPer10)) }
                TableColumn("Answer time (typ / slow)") { r in Text(r.summary.latP50.isNaN ? "–" : "\(sec(r.summary.latP50)) / \(sec(r.summary.latP90))") }
                TableColumn("Errors") { r in Text("\(r.summary.errors)") }
            }
            .frame(minHeight: 200)

            ForEach(model.notes, id: \.self) { n in
                Label(n, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            Text("Claude rows are recorded answers on the same talks (latency from earlier measurements), so they cost nothing to show. Higher “on the right point” and lower catch-up are better.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 620)
        .onAppear { model.refreshDiagnostics(accessCode: app.accessCode) }
        .onChange(of: model.running) { _, _ in copied = false }
    }

    private func pct(_ x: Double) -> String { x.isNaN ? "–" : String(format: "%.1f%%", x) }
    private func sec(_ x: Double) -> String { x.isNaN ? "–" : String(format: "%.1f s", x) }
    private func num(_ x: Double) -> String { x.isNaN ? "–" : String(format: "%.1f", x) }
}
