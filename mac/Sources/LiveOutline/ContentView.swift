import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            switch model.mode {
            case .edit: EditorView().transition(.opacity)
            case .present: PresenterView().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.mode)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: Binding(
                    get: { model.mode },
                    set: { if $0 != model.mode { model.toggleMode() } }
                )) {
                    Label("Edit", systemImage: "square.and.pencil").tag(AppModel.Mode.edit)
                    Label("Present", systemImage: "play.rectangle").tag(AppModel.Mode.present)
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
                .fixedSize()
            }
            ToolbarItem(placement: .primaryAction) {
                MicButton()
            }
        }
        .sheet(item: Binding(
            get: { model.tutorial },
            set: { if $0 == nil, model.tutorial != nil { model.finishTutorial() } }
        )) { t in
            TutorialView(pages: t.pages, whatsNew: t.whatsNew) { model.finishTutorial() }
        }
        .task { model.showTutorialIfNeeded() }
        .alert("Can't listen", isPresented: Binding(
            get: { model.listener.errorMessage != nil },
            set: { if !$0 { model.listener.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.listener.errorMessage ?? "")
        }
    }
}

struct MicButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let on = model.listener.isListening
        Button {
            model.toggleListening()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "waveform" : "mic.fill")
                    .symbolEffect(.variableColor.iterative, isActive: on)
                Text(on ? "Listening" : "Listen")
            }
            .padding(.horizontal, 6)
        }
        .tint(on ? .red : .accentColor)
        .buttonStyle(.borderedProminent)
        .disabled(model.mode != .present)
        .help(on ? "Stop listening (⌘L)" : "Start following your voice (⌘L)")
    }
}
