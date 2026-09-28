import SwiftUI
import MatcherCore

// MARK: - Pages
//
// Adding a feature? Add a page here with `addedIn` set higher than every existing page.
// New users see every page; people who update see only pages newer than the last tutorial they saw.

struct TutorialPage: Identifiable {
    enum Demo { case welcome, outline, follow, meaning, correct, compare, updates, shortcuts }

    let id: String
    let addedIn: Int
    let symbol: String
    let title: String
    let body: String
    let demo: Demo
}

enum Tutorial {
    static let pages: [TutorialPage] = [
        TutorialPage(id: "welcome", addedIn: 1, symbol: "sparkles", title: "Welcome to Live Outline",
                     body: "Your outline follows along as you speak, so you and your audience always know which point you're on.",
                     demo: .welcome),
        TutorialPage(id: "outline", addedIn: 1, symbol: "list.bullet.indent", title: "Write your outline",
                     body: "One point per line. Indent a line to make it a sub-point. The preview on the right shows how it will look.",
                     demo: .outline),
        TutorialPage(id: "follow", addedIn: 1, symbol: "waveform", title: "Present and just talk",
                     body: "Click Present, then press Space to start listening. The point you're on turns bold and the highlight glides along with you.",
                     demo: .follow),
        TutorialPage(id: "meaning", addedIn: 14, symbol: "sparkles", title: "It follows what you mean",
                     body: "Say it your own way. Apple's on-device model (or a tiny meaning model on older Macs) works out which point you're on from what you mean, right on your Mac, for free. Side stories and \"like I said earlier\" don't move the highlight.",
                     demo: .meaning),
        TutorialPage(id: "correct", addedIn: 1, symbol: "arrow.left.arrow.right", title: "Nudge it when it's wrong",
                     body: "Press ← or → (or click a line) to move the highlight yourself. You always win, and listening carries on from there.",
                     demo: .correct),
        TutorialPage(id: "updates", addedIn: 12, symbol: "arrow.down.circle", title: "Always up to date",
                     body: "Live Outline checks for new versions every day. When one is ready, click Install Update and it relaunches with the new features.",
                     demo: .updates),
        TutorialPage(id: "compare", addedIn: 14, symbol: "flag.checkered", title: "Race the judges",
                     body: "Curious how well your Mac keeps up? Help → Compare Judges plays practice talks through Apple's model, the tiny model and Claude, and shows who stays on the right point and how fast.",
                     demo: .compare),
        TutorialPage(id: "shortcuts", addedIn: 1, symbol: "keyboard", title: "Handy shortcuts",
                     body: "You can reopen this tutorial any time from the Help menu.",
                     demo: .shortcuts),
    ]

    /// Pages to show someone who last saw the tutorial at `lastSeen` (0 = never).
    static func pagesToShow(lastSeen: Int) -> [TutorialPage] {
        tutorialPagesToShow(addedIn: pages.map(\.addedIn), lastSeen: lastSeen).map { pages[$0] }
    }

    static var newest: Int { pages.map(\.addedIn).max() ?? 0 }
}

// MARK: - Sheet

struct TutorialView: View {
    let pages: [TutorialPage]
    let whatsNew: Bool
    let onDone: () -> Void
    @State private var index = 0

    var body: some View {
        let page = pages[index]
        let isLast = index == pages.count - 1
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.purple.opacity(0.25)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                TutorialDemo(demo: page.demo)
                    .id(page.id)   // restart the animation on each page
                    .frame(width: 440, height: 240)
                    .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 20, y: 10)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .frame(height: 300)

            VStack(spacing: 10) {
                if whatsNew {
                    Text("NEW IN LIVE OUTLINE")
                        .font(.caption.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(Color.accentColor)
                }
                Label(page.title, systemImage: page.symbol)
                    .font(.title2.weight(.bold))
                Text(page.body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .id("text-" + page.id)
            .transition(.opacity)

            Spacer(minLength: 12)

            HStack {
                Button("Skip") { onDone() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .opacity(isLast ? 0 : 1)
                    .disabled(isLast)
                Spacer()
                HStack(spacing: 7) {
                    ForEach(pages.indices, id: \.self) { i in
                        Capsule()
                            .fill(i == index ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: i == index ? 18 : 7, height: 7)
                            .onTapGesture { index = i }
                    }
                }
                Spacer()
                if index > 0 {
                    Button("Back") { index -= 1 }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                }
                Button(isLast ? (whatsNew ? "Done" : "Get Started") : "Next") {
                    if isLast { onDone() } else { index += 1 }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                Button("") { if !isLast { index += 1 } }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .hidden()
                    .frame(width: 0)
            }
            .padding(20)
        }
        .frame(width: 620, height: 580)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: index)
    }
}

// MARK: - Demos

private struct TutorialDemo: View {
    let demo: TutorialPage.Demo

    private static let lines = ["Welcome", "Why sleep matters", "  Memory", "Tips for better sleep", "  Avoid screens before bed", "Questions"]

    var body: some View {
        switch demo {
        case .welcome:
            WelcomeDemo()
        case .outline:
            TypingOutlineDemo(lines: Self.lines)
        case .follow:
            MiniOutlineDemo(lines: Self.lines, frames: [
                .init(transcript: "Hi everyone, welcome…", active: 0),
                .init(transcript: "…so why does sleep matter so much?", active: 1),
                .init(transcript: "…your memory gets sorted while you sleep", active: 2),
                .init(transcript: "…here are my tips for better sleep", active: 3),
                .init(transcript: "…any questions?", active: 5),
            ])
        case .correct:
            MiniOutlineDemo(lines: Self.lines, frames: [
                .init(transcript: "…the brain files away your day while you sleep", active: 1, hold: 1.8),
                .init(transcript: "…the brain files away your day while you sleep", active: 1, key: "→", hold: 0.7),
                .init(transcript: "…the brain files away your day while you sleep", active: 2, hold: 2.4),
            ])
        case .meaning:
            MiniOutlineDemo(lines: Self.lines, frames: [
                .init(transcript: "…honestly, my phone sleeps in the kitchen now", active: 3, hold: 1.6),
                .init(transcript: "…honestly, my phone sleeps in the kitchen now", active: 3, badge: "Thinking…", hold: 0.8),
                .init(transcript: "…honestly, my phone sleeps in the kitchen now", active: 4, badge: "On your Mac", hold: 2.0),
                .init(transcript: "…funny story, my dog once ate a charger", active: 4, badge: "Just an aside", hold: 2.4),
            ])
        case .compare:
            RaceDemo()
        case .updates:
            UpdateDemo()
        case .shortcuts:
            ShortcutsDemo()
        }
    }
}

private struct DemoFrame {
    var transcript = ""
    var active = 0
    var badge: String?
    var key: String?
    var hold: Double = 1.7
}

/// A tiny outline that plays a looping script: highlight moves, transcript changes, badges pop in.
private struct MiniOutlineDemo: View {
    let lines: [String]
    let frames: [DemoFrame]
    @State private var step = 0
    @Namespace private var ns

    var body: some View {
        let f = frames[step]
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(lines.indices, id: \.self) { i in
                    let sub = lines[i].hasPrefix("  ")
                    Text(lines[i].trimmingCharacters(in: .whitespaces))
                        .font(.system(size: sub ? 12 : 13.5, weight: i == f.active ? .bold : (sub ? .regular : .medium)))
                        .foregroundStyle(i < f.active ? Color.secondary : Color.primary)
                        .padding(.vertical, 3.5)
                        .padding(.leading, sub ? 22 : 10)
                        .padding(.trailing, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            if i == f.active {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.16))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(Color.accentColor).frame(width: 3).padding(.vertical, 5)
                                    }
                                    .matchedGeometryEffect(id: "highlight", in: ns)
                            }
                        }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.variableColor.iterative)
                Text(f.transcript)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                Spacer(minLength: 4)
                if let key = f.key {
                    KeyCap(key).transition(.scale.combined(with: .opacity))
                }
                if let badge = f.badge {
                    Label(badge, systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(10)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: step)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(frames[step].hold))
                step = (step + 1) % frames.count
            }
        }
    }
}

/// Lines appear one by one, as if being typed, with the preview filling in.
private struct TypingOutlineDemo: View {
    let lines: [String]
    @State private var shown = 0

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(0..<shown, id: \.self) { i in
                    Text(lines[i]).font(.system(size: 11, design: .monospaced))
                }
                if shown < lines.count {
                    Rectangle().fill(Color.accentColor).frame(width: 2, height: 13)
                        .opacity(0.8)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(14)
            .background(Color.secondary.opacity(0.06))

            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<shown, id: \.self) { i in
                    let sub = lines[i].hasPrefix("  ")
                    HStack(spacing: 6) {
                        Circle().fill(sub ? Color.secondary.opacity(0.5) : Color.accentColor)
                            .frame(width: sub ? 4 : 6, height: sub ? 4 : 6)
                        Text(lines[i].trimmingCharacters(in: .whitespaces))
                            .font(.system(size: sub ? 11.5 : 13, weight: sub ? .regular : .semibold))
                    }
                    .padding(.leading, sub ? 14 : 0)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(14)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: shown)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(shown == lines.count ? 2.5 : 0.55))
                shown = shown == lines.count ? 0 : shown + 1
            }
        }
    }
}

private struct WelcomeDemo: View {
    @State private var on = false

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .scaleEffect(on ? 1 : 0.85)
                .shadow(color: Color.accentColor.opacity(0.4), radius: on ? 18 : 6)
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                Image(systemName: "arrow.right")
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
            }
            .font(.title3)
            .foregroundStyle(Color.accentColor)
            .symbolEffect(.pulse, isActive: on)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { on = true }
        }
    }
}

private struct UpdateDemo: View {
    @State private var pressed = false

    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text("A new version of Live Outline is available!")
                    .font(.system(size: 13, weight: .semibold))
                Text("It follows what you mean, right on your Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Text("Install Update")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                        .scaleEffect(pressed ? 0.92 : 1)
                }
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(24)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.easeInOut(duration: 0.15)) { pressed = true }
                try? await Task.sleep(for: .seconds(0.2))
                withAnimation(.easeInOut(duration: 0.15)) { pressed = false }
            }
        }
    }
}

/// Three lanes racing: who stays on the right point, and how fast.
private struct RaceDemo: View {
    private let lanes: [(name: String, symbol: String, share: Double)] = [
        ("On your Mac", "cpu", 0.86), ("Tiny model", "sparkles", 0.7), ("Claude", "cloud", 0.9),
    ]
    @State private var go = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(lanes, id: \.name) { lane in
                HStack(spacing: 10) {
                    Label(lane.name, systemImage: lane.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 110, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15))
                            Capsule().fill(Color.accentColor.gradient)
                                .frame(width: geo.size.width * (go ? lane.share : 0.04))
                        }
                    }
                    .frame(height: 12)
                }
            }
            HStack {
                Spacer()
                Text("Copy Results as JSON")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .opacity(go ? 1 : 0)
            }
        }
        .padding(24)
        .task {
            while !Task.isCancelled {
                withAnimation(.easeOut(duration: 1.8)) { go = true }
                try? await Task.sleep(for: .seconds(3.4))
                withAnimation(.easeIn(duration: 0.3)) { go = false }
                try? await Task.sleep(for: .seconds(0.6))
            }
        }
    }
}

private struct ShortcutsDemo: View {
    private let rows: [(String, String)] = [
        ("Space", "Start or stop listening"),
        ("← →", "Move the highlight"),
        ("⇧⌘P", "Present / back to editing"),
        ("⌃⌘F", "Full screen"),
        ("⌘,", "Settings"),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            ForEach(rows, id: \.0) { key, what in
                GridRow {
                    KeyCap(key).gridColumnAlignment(.trailing)
                    Text(what).font(.system(size: 13))
                }
            }
        }
        .padding(20)
    }
}

private struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.4)))
            .shadow(color: .black.opacity(0.12), radius: 0, y: 1)
    }
}
