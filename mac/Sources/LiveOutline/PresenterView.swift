import SwiftUI
import MatcherCore

struct PresenterView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var highlight
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            background

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.items) { item in
                            row(item)
                                .id(item.id)
                                .onTapGesture { model.select(item.id) }
                        }
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                    .padding(.horizontal, 48)
                    .padding(.top, 72)
                    .padding(.bottom, 160)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .onChange(of: model.current) { _, new in
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }

            VStack(spacing: 0) {
                ProgressHeader()
                Spacer()
                TranscriptBar()
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.rightArrow) { model.step(1); return .handled }
        .onKeyPress(.downArrow) { model.step(1); return .handled }
        .onKeyPress(.leftArrow) { model.step(-1); return .handled }
        .onKeyPress(.upArrow) { model.step(-1); return .handled }
        .onKeyPress(.space) { model.toggleListening(); return .handled }
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: model.current)
    }

    private var background: some View {
        LinearGradient(
            colors: [Color(nsColor: .windowBackgroundColor), Color.accentColor.opacity(0.08)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func row(_ item: OutlineItem) -> some View {
        let isActive = item.id == model.current
        let isPast = item.id < model.current
        let size: CGFloat = item.level == 0 ? 34 : 26

        Text(item.text)
            .font(.system(size: size, weight: isActive ? .bold : (item.level == 0 ? .semibold : .regular)))
            .foregroundStyle(isActive ? Color.primary : (isPast ? Color.secondary.opacity(0.55) : Color.primary.opacity(0.85)))
            .scaleEffect(isActive ? 1.03 : 1, anchor: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: 5)
                                .padding(.vertical, 10)
                        }
                        .shadow(color: Color.accentColor.opacity(0.25), radius: 18, y: 6)
                        .matchedGeometryEffect(id: "highlight", in: highlight)
                }
            }
            .padding(.leading, CGFloat(item.level) * 36)
            .contentShape(Rectangle())
    }
}

private struct ProgressHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let total = max(model.items.count, 1)
        let fraction = Double(model.current + 1) / Double(total)
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Color.accentColor)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 4)
            Text("\(model.current + 1) of \(model.items.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 48)
        .padding(.top, 16)
        .animation(.easeInOut, value: model.current)
    }
}

private struct TranscriptBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let listener = model.listener
        HStack(spacing: 14) {
            LevelMeter(level: listener.isListening ? listener.level : 0)
                .frame(width: 44, height: 22)
            Text(placeholderOr(listener.transcript))
                .font(.system(size: 15))
                .foregroundStyle(listener.transcript.isEmpty ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .leading, endPoint: .trailing))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
    }

    private func placeholderOr(_ text: String) -> String {
        if !text.isEmpty { return text }
        return model.listener.isListening ? "Listening…" : "Press Space or ⌘L to follow your voice · ← → to move by hand"
    }
}

private struct LevelMeter: View {
    var level: Float
    private let bars = 5

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<bars, id: \.self) { i in
                let shape: CGFloat = [0.5, 0.8, 1.0, 0.8, 0.5][i]
                Capsule()
                    .fill(level > 0.01 ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 4, height: max(4, 22 * CGFloat(level) * shape))
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
    }
}
