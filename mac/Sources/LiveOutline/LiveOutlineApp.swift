import SwiftUI

@main
struct LiveOutlineApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Live Outline") {
            ContentView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandMenu("Presentation") {
                Button(model.mode == .present ? "Edit Outline" : "Start Presenting") { model.toggleMode() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button(model.listener.isListening ? "Stop Listening" : "Start Listening") { model.toggleListening() }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(model.mode != .present)
                Divider()
                Button("Next Point") { model.step(1) }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(model.mode != .present)
                Button("Previous Point") { model.step(-1) }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(model.mode != .present)
            }
        }
    }
}
