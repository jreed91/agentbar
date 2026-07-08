import SwiftUI

/// Renders one `AskUserQuestion` item: each question shows its options (single-select
/// buttons or multi-select toggles) plus a free-text field as an alternative answer.
/// Submit resolves the whole item; "Answer in terminal" falls back via passthrough.
struct QuestionItemView: View {
    @ObservedObject var item: PendingItem
    let questions: [AskQuestion]
    let queue: QueueStore

    /// Per-question selected option indices.
    @State private var selected: [Int: Set<Int>] = [:]
    /// Per-question typed reply (overrides the selection when non-empty).
    @State private var typed: [Int: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                questionView(index: index, question: question)
            }

            HStack {
                Button("Submit") { submitAll() }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("Answer in terminal") { queue.passthrough(item: item) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func questionView(index: Int, question: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header = question.header, !header.isEmpty {
                Text(header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            Text(question.question)
                .font(.subheadline.weight(.medium))

            ForEach(Array(question.options.enumerated()), id: \.offset) { optionIndex, option in
                optionRow(
                    questionIndex: index,
                    optionIndex: optionIndex,
                    option: option,
                    multiSelect: question.multiSelect
                )
            }

            TextField("Or type a reply…", text: typedBinding(index))
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private func optionRow(questionIndex: Int, optionIndex: Int, option: AskQuestionOption, multiSelect: Bool) -> some View {
        if multiSelect {
            Toggle(isOn: multiBinding(questionIndex: questionIndex, optionIndex: optionIndex)) {
                optionLabel(option)
            }
            .toggleStyle(.checkbox)
        } else {
            Button {
                selected[questionIndex] = [optionIndex]
                // A single single-select question is answered in one click.
                if questions.count == 1 {
                    submitAll()
                }
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: isSelected(questionIndex, optionIndex) ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected(questionIndex, optionIndex) ? Color.accentColor : .secondary)
                    optionLabel(option)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func optionLabel(_ option: AskQuestionOption) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(option.label)
            if let description = option.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bindings & state

    private func isSelected(_ questionIndex: Int, _ optionIndex: Int) -> Bool {
        selected[questionIndex]?.contains(optionIndex) ?? false
    }

    private func typedBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { typed[index] ?? "" },
            set: { typed[index] = $0 }
        )
    }

    private func multiBinding(questionIndex: Int, optionIndex: Int) -> Binding<Bool> {
        Binding(
            get: { isSelected(questionIndex, optionIndex) },
            set: { isOn in
                var set = selected[questionIndex] ?? []
                if isOn { set.insert(optionIndex) } else { set.remove(optionIndex) }
                selected[questionIndex] = set
            }
        )
    }

    // MARK: - Submission

    private func submitAll() {
        var answers: [(question: String, answer: String)] = []
        for (index, question) in questions.enumerated() {
            let label = (question.header?.isEmpty == false) ? question.header! : question.question
            let typedText = (typed[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !typedText.isEmpty {
                answers.append((question: label, answer: typedText))
            } else if let indices = selected[index], !indices.isEmpty {
                let labels = indices.sorted().compactMap { optionIndex -> String? in
                    optionIndex < question.options.count ? question.options[optionIndex].label : nil
                }
                answers.append((question: label, answer: labels.joined(separator: ", ")))
            }
        }
        guard !answers.isEmpty else { return }
        queue.answerQuestion(item: item, answers: answers)
    }
}
