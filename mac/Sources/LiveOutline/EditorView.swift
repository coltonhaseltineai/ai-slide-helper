import SwiftUI
import MatcherCore

struct EditorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your outline")
                    .font(.headline)
                Text("One point per line. Indent to nest. Add hidden hints with [cues: word, word].")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextEditor(text: $model.outlineText)
                    .font(.system(size: 14, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            }
            .padding(24)
            .frame(minWidth: 320)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Preview").font(.headline)
                        Text("Say it your own way. Live Outline follows what you mean, not just these words.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.toggleMode()
                    } label: {
                        Label("Present", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.previewItems) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle()
                                    .fill(item.level == 0 ? Color.accentColor : Color.secondary.opacity(0.5))
                                    .frame(width: item.level == 0 ? 7 : 5, height: item.level == 0 ? 7 : 5)
                                Text(item.text)
                                    .font(item.level == 0 ? .title3.weight(.semibold) : .body)
                                if !item.cues.isEmpty {
                                    Text(item.cues.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                            .padding(.leading, CGFloat(item.level) * 22)
                            .padding(.bottom, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(24)
            .frame(minWidth: 300)
        }
    }
}
