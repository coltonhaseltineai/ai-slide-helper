import SwiftUI

/// The words Live Outline has learned for one outline line, as removable tags, plus a way to add your own.
struct LearnedWordsRow: View {
    @Environment(AppModel.self) private var model
    let lineText: String
    @State private var adding = false
    @State private var newWord = ""

    var body: some View {
        let words = model.learnedWords(for: lineText)
        FlowLayout(spacing: 5) {
            ForEach(words, id: \.self) { word in
                HStack(spacing: 3) {
                    Text(word)
                    Button {
                        withAnimation(.snappy) { model.removeLearned(word, for: lineText) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .padding(3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Forget “\(word)” for this point")
                }
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .padding(.leading, 7).padding(.trailing, 3).padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
                .transition(.scale.combined(with: .opacity))
            }
            Button {
                adding = true
            } label: {
                Label(words.isEmpty ? "Teach a word" : "Add", systemImage: "plus")
                    .font(.caption)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .overlay(Capsule().strokeBorder(.quaternary))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Add a word or phrase you tend to say for this point")
            .popover(isPresented: $adding, arrowEdge: .bottom) {
                HStack {
                    TextField("e.g. blue light", text: $newWord)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .onSubmit(save)
                    Button("Add", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(12)
            }
        }
    }

    private func save() {
        withAnimation(.snappy) { model.addLearned(newWord, for: lineText) }
        newWord = ""
        adding = false
    }
}

/// Lays out views left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > maxWidth, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let isFirst = rows[rows.count - 1].indices.isEmpty
            rows[rows.count - 1].indices.append(i)
            rows[rows.count - 1].width += isFirst ? size.width : size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
