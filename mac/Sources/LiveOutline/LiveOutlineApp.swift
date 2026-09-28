import Sparkle
import SwiftUI

/// Started by Launcher (which handles --self-test first).
struct LiveOutlineApp: App {
    @State private var model = AppModel()
    private let updater = AppUpdater()

    var body: some Scene {
        WindowGroup("Live Outline") {
            ContentView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.isAvailable)
            }
            HelpCommands(model: model)
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
        Window("Compare Judges", id: "compare") {
            CompareView()
                .environment(model)
        }
        .defaultSize(width: 900, height: 700)
        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

private struct HelpCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Live Outline Tutorial") { model.showFullTutorial() }
            Button("Compare Judges (Beta)…") { openWindow(id: "compare") }
        }
    }
}

/// Keeps the app up to date with Sparkle: checks daily and offers "Install and Relaunch".
final class AppUpdater {
    private let controller: SPUStandardUpdaterController?

    init() {
        // Only a real app bundle has the update feed settings (not `swift run`).
        let bundled = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = bundled
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}
