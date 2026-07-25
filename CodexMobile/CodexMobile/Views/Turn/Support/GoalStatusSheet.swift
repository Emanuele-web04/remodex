// FILE: GoalStatusSheet.swift
// Purpose: Presents and manages the persisted thread goal for the `/goal` composer command.
// Layer: View Component
// Exports: GoalStatusSheet
// Depends on: SwiftUI, CodexService, CodexThreadGoal

import SwiftUI

struct GoalStatusSheet: View {
    let threadId: String
    // Draft text carried over from the composer when the user typed `/goal <text>`.
    let initialObjectiveDraft: String?
    // Lets the host consume the composer draft once the objective is actually submitted.
    var onObjectiveSubmitted: ((String) -> Void)? = nil

    @Environment(CodexService.self) private var codex
    @Environment(\.dismiss) private var dismiss

    // Editing updates the existing goal in place; creating replaces it (with confirm when unfinished).
    private enum ObjectiveEditorMode {
        case editExisting
        case createNew
    }

    @State private var isEditingObjective = false
    @State private var editorMode: ObjectiveEditorMode = .createNew
    @State private var objectiveDraft = ""
    @State private var tokenBudgetDraft = ""
    @State private var isPerformingAction = false
    @State private var errorMessage: String?
    @State private var isShowingClearConfirmation = false
    @State private var isShowingReplaceConfirmation = false
    @State private var hasLoadedRemoteGoal = false

    private var goal: CodexThreadGoal? {
        codex.goalByThreadID[threadId]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let errorMessage {
                        errorCard(errorMessage)
                    }

                    if isEditingObjective || goal == nil {
                        objectiveEditorCard
                    } else if let goal {
                        goalSummaryCard(goal)
                        goalActionsCard(goal)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .navigationTitle("Goal")
            .navigationBarTitleDisplayMode(.inline)
            .adaptiveNavigationBar()
        }
        .presentationDetents([.medium, .large])
        .task {
            await loadRemoteGoalIfNeeded()
        }
        .confirmationDialog(
            "Clear this goal?",
            isPresented: $isShowingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Goal", role: .destructive) {
                performAction { try await codex.clearThreadGoal(threadId: threadId) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Codex stops pursuing the objective and forgets its goal progress accounting.")
        }
        .confirmationDialog(
            "Replace the current goal?",
            isPresented: $isShowingReplaceConfirmation,
            titleVisibility: .visible
        ) {
            Button("Replace Goal", role: .destructive) {
                // `thread/goal/set` with a new objective atomically replaces the goal and
                // resets usage accounting, so no separate clear (which could drop the goal
                // entirely if the follow-up set failed).
                performAction { try await submitGoalDraft() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current goal is not complete. Replacing it starts the new objective from scratch.")
        }
    }

    // MARK: - Cards

    private func goalSummaryCard(_ goal: CodexThreadGoal) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: goal.status.symbolName)
                    .foregroundStyle(statusColor(goal.status))
                Text(goal.status.displayLabel)
                    .font(AppFont.headline())
                    .foregroundStyle(statusColor(goal.status))
                Spacer()
                Text(goal.usageSummary)
                    .font(AppFont.subheadline().monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(goal.objective)
                .font(AppFont.body())
                .frame(maxWidth: .infinity, alignment: .leading)

            if let tokenBudget = goal.tokenBudget {
                let remaining = goal.remainingTokens ?? 0
                Text("Budget \(CodexThreadGoal.formatTokenCount(tokenBudget)) tokens · \(CodexThreadGoal.formatTokenCount(remaining)) remaining")
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
            }

            if goal.status == .active {
                Text("Codex keeps working toward this goal whenever the chat is idle, until it is complete, paused, or out of budget.")
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func goalActionsCard(_ goal: CodexThreadGoal) -> some View {
        VStack(spacing: 10) {
            if goal.status == .active {
                actionButton("Pause Goal", systemImage: "pause.circle") {
                    performAction {
                        try await codex.setThreadGoal(threadId: threadId, status: .paused)
                    }
                }
            }

            if goal.status.isResumable {
                actionButton("Resume Goal", systemImage: "play.circle") {
                    performAction {
                        try await codex.setThreadGoal(threadId: threadId, status: .active)
                    }
                }
            }

            if goal.status == .complete {
                actionButton("New Goal", systemImage: "plus.circle") {
                    objectiveDraft = initialObjectiveDraft ?? ""
                    tokenBudgetDraft = ""
                    editorMode = .createNew
                    isEditingObjective = true
                }
            } else {
                actionButton("Edit Objective", systemImage: "pencil") {
                    objectiveDraft = goal.objective
                    tokenBudgetDraft = goal.tokenBudget.map(String.init) ?? ""
                    editorMode = .editExisting
                    isEditingObjective = true
                }
            }

            actionButton("Clear Goal", systemImage: "trash", role: .destructive) {
                isShowingClearConfirmation = true
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var objectiveEditorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editorMode == .editExisting ? "Edit Goal" : "New Goal")
                .font(AppFont.headline())

            Text("Describe the outcome, how to verify it, and what must not regress. Codex keeps working toward it across turns.")
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)

            TextEditor(text: $objectiveDraft)
                .frame(minHeight: 120)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )

            TextField("Token budget (optional)", text: $tokenBudgetDraft)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                if goal != nil {
                    Button("Cancel") {
                        isEditingObjective = false
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    submitObjectiveDraft()
                } label: {
                    if isPerformingAction {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(editorMode == .editExisting ? "Save Goal" : "Start Goal")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedObjectiveDraft.isEmpty || isPerformingAction)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .onAppear {
            if objectiveDraft.isEmpty, let initialObjectiveDraft {
                objectiveDraft = initialObjectiveDraft
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(AppFont.footnote())
            .foregroundStyle(.red)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.red.opacity(0.1))
            )
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(isPerformingAction)
    }

    // MARK: - Actions

    private var trimmedObjectiveDraft: String {
        objectiveDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitObjectiveDraft() {
        guard !trimmedObjectiveDraft.isEmpty else { return }

        // Replacing an unfinished goal needs an explicit confirmation, mirroring the Codex TUI.
        if editorMode == .createNew, let goal, goal.status != .complete {
            isShowingReplaceConfirmation = true
            return
        }

        performAction { try await submitGoalDraft() }
    }

    private func submitGoalDraft() async throws {
        try await codex.setThreadGoal(
            threadId: threadId,
            objective: trimmedObjectiveDraft,
            // Only creating/replacing starts the goal. Editing must omit status so a
            // paused/blocked/limited goal keeps its lifecycle state instead of resuming.
            status: editorMode == .createNew ? .active : nil,
            tokenBudget: try resolvedBudgetUpdate()
        )
        onObjectiveSubmitted?(trimmedObjectiveDraft)
        isEditingObjective = false
    }

    // Maps the budget field onto the wire tri-state: an emptied field removes an
    // existing budget (explicit null); omission would silently keep the old value.
    private func resolvedBudgetUpdate() throws -> CodexThreadGoalBudgetUpdate {
        let trimmedBudget = tokenBudgetDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBudget.isEmpty {
            return goal?.tokenBudget != nil ? .clear : .keep
        }
        guard let budget = Int(trimmedBudget), budget > 0 else {
            throw CodexThreadGoalError.invalidBudget
        }
        return .set(budget)
    }

    private func performAction(_ operation: @escaping () async throws -> Void) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        errorMessage = nil

        Task { @MainActor in
            defer { isPerformingAction = false }
            do {
                try await operation()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func loadRemoteGoalIfNeeded() async {
        guard !hasLoadedRemoteGoal else { return }
        hasLoadedRemoteGoal = true
        do {
            // Refresh from the app-server so a stale local mirror cannot mislead the sheet.
            _ = try await codex.readThreadGoal(threadId: threadId)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        // `/goal <text>` opens the editor prefilled so the user can start immediately.
        if let initialObjectiveDraft, !isEditingObjective {
            objectiveDraft = initialObjectiveDraft
            editorMode = .createNew
            isEditingObjective = true
        }
    }

    private func statusColor(_ status: CodexThreadGoalStatus) -> Color {
        switch status {
        case .active:
            return .purple
        case .paused:
            return .secondary
        case .blocked, .usageLimited, .budgetLimited:
            return .orange
        case .complete:
            return .green
        }
    }
}
