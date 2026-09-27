import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Use Claude for smart following", isOn: $model.aiEnabled)
                SecureField("Access code", text: $model.accessCode)
            } footer: {
                Text("Claude helps follow the speaker even when they don't use the outline's words, and remembers the words they use so the app gets quicker over time.")
                    .foregroundStyle(.secondary)
            }
            if let reason = model.aiDisabledReason {
                Section {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                LabeledContent("Words learned", value: "\(model.learnedCount)")
                Button("Forget Learned Words…", role: .destructive) { confirmReset = true }
                    .disabled(model.learnedCount == 0)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Forget everything Live Outline has learned?", isPresented: $confirmReset) {
            Button("Forget", role: .destructive) { model.resetLibrary() }
        }
    }
}
