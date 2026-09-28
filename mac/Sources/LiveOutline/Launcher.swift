import Foundation

/// Entry point. `LiveOutline --self-test` prints a JSON health report and exits (CI runs it on
/// macOS 15 to prove the app still launches where Apple's on-device model framework doesn't exist).
@main
@MainActor
enum Launcher {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            selfTest()
            exit(0)
        }
        LiveOutlineApp.main()
    }

    static func selfTest() {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let report: [String: Any] = [
            "ok": true,
            "arch": arch,
            "macOS": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            "onDevice": OnDevice.status().code,
            "promptVersion": AppResources.promptSet?.current ?? "missing",
            "profiles": AppResources.profiles.keys.sorted(),
            "talks": (AppResources.splits.dev + AppResources.splits.test).filter { AppResources.talkURL($0) != nil }.count,
            "claudeReference": AppResources.url("claude-reference.json") != nil,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])) ?? Data()
        print(String(data: data, encoding: .utf8) ?? "{}")
    }
}
