import SwiftUI

struct AsyncUserInputCardView: View {
    let input: CodexAsyncUserInput
    let onSubmit: ([String]) -> Void

    @State private var answers: [Int: String] = [:]

    private var canSubmit: Bool {
        input.status == .unanswered
            && input.questions.indices.allSatisfy {
                !(answers[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Questions", systemImage: "questionmark.bubble")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(input.questions.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 8) {
                    Text(input.questions[index].title)
                        .font(AppFont.body(weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)

                    if input.status != .unanswered {
                        Text(input.answers?[index] ?? "")
                            .font(AppFont.body(weight: .medium))
                            .foregroundStyle(.primary)
                    } else {
                        if let options = input.questions[index].options {
                            ForEach(options, id: \.self) { option in
                                Button {
                                    answers[index] = option
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: answers[index] == option ? "largecircle.fill.circle" : "circle")
                                        Text(option)
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        TextField(
                            input.questions[index].options == nil ? "Your answer" : "Or write an answer",
                            text: Binding(
                                get: { answers[index] ?? "" },
                                set: { answers[index] = $0 }
                            ),
                            axis: .vertical
                        )
                        .font(AppFont.body())
                        .foregroundStyle(.primary)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(minHeight: 44)
                        .background(Color(.secondarySystemFill).opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color(.separator).opacity(0.25), lineWidth: 1)
                        }
                    }
                }
            }

            switch input.status {
            case .unanswered:
                Button {
                    onSubmit(input.questions.indices.map { answers[$0] ?? "" })
                } label: {
                    Text(input.questions.count == 1 ? "Send answer" : "Send answers")
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(canSubmit ? Color(.systemBackground) : Color(.secondaryLabel))
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(canSubmit ? Color.primary : Color(.secondarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
            case .submitting:
                Label("Sending answers…", systemImage: "arrow.up.circle")
                    .foregroundStyle(.secondary)
            case .queued:
                Label("Answers queued until this run finishes", systemImage: "clock")
                    .foregroundStyle(.secondary)
            case .answered:
                Label("Answered", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .uncertain:
                Label("Check on your Mac whether the answers arrived", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onAppear(perform: restoreDraftAnswers)
        .onChange(of: input.status) { _, status in
            if status == .unanswered { restoreDraftAnswers() }
        }
    }

    private func restoreDraftAnswers() {
        guard let savedAnswers = input.answers else { return }
        for (index, answer) in savedAnswers.enumerated() where input.questions.indices.contains(index) {
            answers[index] = answer
        }
    }
}
