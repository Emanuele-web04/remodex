// FILE: CommandExecutionViews.swift
// Purpose: Pure UI components for command execution cards and detail sheets.
// Layer: View Components
// Exports: CommandExecutionCardBody, CommandExecutionDetailSheet, CommandExecutionStatusModel, CommandExecutionStatusAccent
// Depends on: SwiftUI, CommandExecutionDetails, AppFont

import SwiftUI

// MARK: - Models

enum CommandExecutionStatusAccent: String {
    case running
    case completed
    case failed

    // Keep tool-call status colors aligned with the inline command language used elsewhere in the app.
    private static let commandColor = Color(.command)

    var color: Color {
        switch self {
        case .running:
            return Self.commandColor
        case .completed:
            return .mint
        case .failed:
            return .red
        }
    }
}

struct CommandExecutionStatusModel {
    let command: String
    let statusLabel: String
    let accent: CommandExecutionStatusAccent
}

// MARK: - Card Body

struct CommandExecutionCardBody: View {
    let command: String
    let statusLabel: String
    let accent: CommandExecutionStatusAccent

    var body: some View {
        HStack(spacing: 10) {
            accent.color.opacity(0.95)
                .frame(width: 3)
                .clipShape(Capsule())

            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent.color)

                Text(command)
                    .font(AppFont.mono(.subheadline))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                Text(statusLabel)
                    .font(AppFont.mono(.caption))
                    .foregroundStyle(accent.color)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        // Tool rows update often while commands stream; keep the subtree static to avoid whole-row flashing.
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

// MARK: - Detail Sheet

struct CommandExecutionDetailSheet: View {
    let status: CommandExecutionStatusModel
    let details: CommandExecutionDetails?
    @Environment(\.dismiss) private var dismiss
    @State private var isOutputExpanded = false
    private let commandAccent = CommandExecutionStatusAccent.running.color

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                commandSection
                metadataSection
                if let details, !details.outputTail.isEmpty {
                    outputSection
                }
            }
            .padding()
        }
        .presentationDragIndicator(.visible)
    }

    private var commandSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Command", systemImage: "terminal.fill")
                .font(AppFont.mono(.caption))
                .foregroundStyle(commandAccent)

            Text(details?.fullCommand ?? status.command)
                .font(AppFont.mono(.callout))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let cwd = details?.cwd, !cwd.isEmpty {
                metadataRow(label: "Directory", value: cwd)
            }
            if let exitCode = details?.exitCode {
                metadataRow(
                    label: "Exit code",
                    value: "\(exitCode)",
                    valueColor: exitCode == 0 ? .green : .red
                )
            }
            if let durationMs = details?.durationMs {
                metadataRow(label: "Duration", value: formattedDuration(durationMs))
            }
            metadataRow(label: "Status", value: status.statusLabel, valueColor: status.accent.color)
        }
    }

    private func metadataRow(label: String, value: String, valueColor: Color = .primary) -> some View {
        HStack {
            Text(label)
                .font(AppFont.mono(.caption))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(AppFont.mono(.caption))
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isOutputExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOutputExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Output (last \(CommandExecutionDetails.maxOutputLines) lines)")
                        .font(AppFont.mono(.caption))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if isOutputExpanded, let output = details?.outputTail {
                Text(output)
                    .font(AppFont.mono(.caption2))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
            }
        }
    }

    private func formattedDuration(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        let seconds = Double(ms) / 1000.0
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        return "\(minutes)m \(remainingSeconds)s"
    }
}

// MARK: - Previews

#Preview("Command Card — Interactive") {
    struct InteractivePreview: View {
        @State private var isShowingSheet = false

        private let status = CommandExecutionStatusModel(
            command: "npm install",
            statusLabel: "completed",
            accent: .completed
        )
        private let details = CommandExecutionDetails(
            fullCommand: "/usr/bin/bash -lc \"cd /home/user/project && npm install --save-dev typescript @types/node\"",
            cwd: "/home/user/project",
            exitCode: 0,
            durationMs: 4320,
            outputTail: """
            added 127 packages in 4s

            15 packages are looking for funding
              run `npm fund` for details
            """
        )

        var body: some View {
            VStack(spacing: 16) {
                CommandExecutionCardBody(
                    command: "/usr/bin/bash -lc \"cd /home/user/project && npm install\"",
                    statusLabel: "running",
                    accent: .running
                )
                    .contentShape(Rectangle())
                    .onTapGesture { isShowingSheet = true }

                CommandExecutionCardBody(
                    command: "git status",
                    statusLabel: "completed",
                    accent: .completed
                )

                CommandExecutionCardBody(
                    command: "python3 train.py --epochs 100 --lr 0.001 --batch-size 32 --output /tmp/model",
                    statusLabel: "failed",
                    accent: .failed
                )
            }
            .padding(.horizontal, 16)
            .sheet(isPresented: $isShowingSheet) {
                CommandExecutionDetailSheet(status: status, details: details)
                    .presentationDetents([.medium, .large])
            }
        }
    }
    return InteractivePreview()
}

#Preview("Detail Sheet — Full") {
    CommandExecutionDetailSheet(
        status: CommandExecutionStatusModel(
            command: "npm install",
            statusLabel: "completed",
            accent: .completed
        ),
        details: CommandExecutionDetails(
            fullCommand: "/usr/bin/bash -lc \"cd /home/user/project && npm install --save-dev typescript @types/node\"",
            cwd: "/home/user/project",
            exitCode: 0,
            durationMs: 4320,
            outputTail: """
            added 127 packages in 4s

            15 packages are looking for funding
              run `npm fund` for details
            """
        )
    )
}

#Preview("Detail Sheet — Failed") {
    CommandExecutionDetailSheet(
        status: CommandExecutionStatusModel(
            command: "npm test",
            statusLabel: "failed",
            accent: .failed
        ),
        details: CommandExecutionDetails(
            fullCommand: "/usr/bin/bash -lc \"cd /home/user/project && npm test\"",
            cwd: "/home/user/project",
            exitCode: 1,
            durationMs: 890,
            outputTail: """
            FAIL src/utils.test.ts
              expected 3 to equal 4

            Tests: 1 failed, 12 passed, 13 total
            """
        )
    )
}

#Preview("Detail Sheet — No Details") {
    CommandExecutionDetailSheet(
        status: CommandExecutionStatusModel(
            command: "git push origin main",
            statusLabel: "running",
            accent: .running
        ),
        details: nil
    )
}
