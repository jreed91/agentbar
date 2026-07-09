import SwiftUI

/// Renders one `AskUserQuestion` item as a read-only notification: each question and its
/// options are shown for context, but you answer in the terminal. The footer brings the
/// terminal forward and lets you dismiss the row.
struct QuestionItemView: View {
    @ObservedObject var item: PendingItem
    let questions: [AskQuestion]
    let queue: QueueStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                questionView(question)
            }
            AttentionFooter(item: item, queue: queue)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func questionView(_ question: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header = question.header, !header.isEmpty {
                Text(header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            Text(question.question)
                .font(.subheadline.weight(.medium))

            ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                optionRow(option)
            }
        }
    }

    private func optionRow(_ option: AskQuestionOption) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(option.label)
                if let description = option.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}
