import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var onDevice = OnDevice.status()
    @State private var checking = false
    @State private var checkResult: String?
    @State private var copied = false
    private var store: ModelStore { ModelStore.shared }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Follow by meaning", selection: $model.followMode) {
                    ForEach(AppModel.FollowMode.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text(model.followMode.detail + " Nothing you say is saved.")
                    .foregroundStyle(.secondary)
            }

            Section("Apple on-device model") {
                LabeledContent("Status") {
                    Label(onDevice.label, systemImage: onDevice.isReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(onDevice.isReady ? .green : .orange)
                }
                if !onDevice.isReady {
                    Text(onDevice.message).font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button(checking ? "Checking…" : "Check Now") { check() }
                        .disabled(checking)
                    if let checkResult { Text(checkResult).font(.callout).foregroundStyle(.secondary) }
                }
            }

            Section("Tiny meaning model") {
                LabeledContent("Status") {
                    switch store.state {
                    case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .downloading: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Downloading…") }
                    case .notDownloaded: Text("Not downloaded").foregroundStyle(.secondary)
                    case .failed(let why): Text(why).foregroundStyle(.orange).lineLimit(2)
                    }
                }
                if store.state != .ready {
                    Button("Download (about 15 MB)") { Task { await store.ensure() } }
                        .disabled(store.state == .downloading)
                }
            }

            Section {
                SecureField("Access code", text: $model.accessCode)
            } header: {
                Text("Claude")
            } footer: {
                Text("Only used when “Follow by meaning” is set to Claude.")
                    .foregroundStyle(.secondary)
            }

            if let s = model.lastStats {
                Section("Last presentation") {
                    LabeledContent("Followed by", value: AppModel.Engine(rawValue: s.engine)?.label ?? s.engine)
                    LabeledContent("Length", value: String(format: "%.1f min", s.minutes))
                    if s.judgeCalls > 0 {
                        LabeledContent("Questions asked", value: "\(s.judgeCalls)")
                        if let p50 = s.latency(0.5), let p90 = s.latency(0.9) {
                            LabeledContent("Answer time", value: String(format: "%.1f s typical, %.1f s slow", p50, p90))
                        }
                    }
                    let errs = s.errors.values.reduce(0, +)
                    if errs > 0 { LabeledContent("Problems", value: s.errors.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) }
                    Button(copied ? "Copied" : "Copy Stats") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(s.summaryJSON, forType: .string)
                        copied = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { onDevice = OnDevice.status() }
    }

    private func check() {
        checking = true
        checkResult = nil
        Task {
            let r = await OnDevice.checkNow()
            onDevice = r.status
            checkResult = r.seconds.map { String(format: "Answered in %.1f s", $0) } ?? r.status.label
            checking = false
        }
    }
}
