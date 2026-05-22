// FILE: SidebarNewChatProjectPickerSheet.swift
// Purpose: Minimal "Start new chat" sheet that lets the user pick a project,
//          worktree, and optionally Quick Chat.
// Layer: View
// Exports: SidebarNewChatProjectPickerSheet
// Depends on: SidebarProjectChoice, AppFont, CodexWorktreeIcon

import SwiftUI

struct SidebarNewChatProjectPickerSheet: View {
    let choices: [SidebarProjectChoice]
    var showsWithoutProjectOption = true
    var showsWorktreeOptions = true
    let onSelectProject: (String) -> Void
    let onSelectWorktreeProject: (String) -> Void
    let onSelectWithoutProject: () -> Void
    let onBrowseLocalFolder: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !choices.isEmpty {
                    Section("Local") {
                        ForEach(choices) { choice in
                            Button {
                                dismiss()
                                onSelectProject(choice.projectPath)
                            } label: {
                                projectRow(
                                    icon: AnyView(
                                        Group {
                                            if choice.iconSystemName == "arrow.triangle.branch" {
                                                CodexWorktreeIcon(pointSize: 16, weight: .medium)
                                            } else {
                                                RemodexIcon.image(systemName: choice.iconSystemName)
                                                    .font(AppFont.body(weight: .medium))
                                            }
                                        }
                                        .foregroundStyle(.secondary)
                                    ),
                                    title: choice.label,
                                    subtitle: nil
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if showsWorktreeOptions {
                        Section("Worktree") {
                            ForEach(choices) { choice in
                                Button {
                                    dismiss()
                                    onSelectWorktreeProject(choice.projectPath)
                                } label: {
                                    projectRow(
                                        icon: AnyView(
                                            CodexWorktreeIcon(pointSize: 16, weight: .medium)
                                                .foregroundStyle(.secondary)
                                        ),
                                        title: choice.label,
                                        subtitle: "Detached worktree from the default branch."
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    Section {
                        Text("No recent project chats yet.")
                            .font(AppFont.body())
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Local")
                    }
                }

                Section {
                    Button {
                        onBrowseLocalFolder()
                    } label: {
                        projectRow(
                            icon: AnyView(
                                RemodexIcon.image(systemName: "folder.badge.plus")
                                    .font(AppFont.body(weight: .medium))
                                    .foregroundStyle(.secondary)
                            ),
                            title: "Add Local Folder",
                            subtitle: "Browse or create a folder on your device."
                        )
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Add")
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }

                if showsWithoutProjectOption {
                    Section {
                        Button {
                            dismiss()
                            onSelectWithoutProject()
                        } label: {
                            projectRow(
                                icon: AnyView(
                                    RemodexIcon.image(systemName: "bubble.left.and.bubble.right")
                                        .font(AppFont.body(weight: .medium))
                                        .foregroundStyle(.secondary)
                                ),
                                title: "Quick Chat",
                                subtitle: "Start a chat without a working directory."
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("Start new chat")
            .navigationBarTitleDisplayMode(.inline)
            .tint(.primary)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                    .tint(.secondary)
                }
            }
        }
        .presentationDetents(choices.count > 4 ? [.fraction(0.75), .large] : [.fraction(0.75)])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func projectRow(icon: AnyView, title: String, subtitle: String?) -> some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 12) {
            icon
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let subtitle {
                    Text(subtitle)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            RemodexIcon.image(systemName: "chevron.right")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Previews

#if DEBUG
private enum SidebarNewChatProjectPickerSheetPreviewData {
    static let sampleChoices: [SidebarProjectChoice] = [
        SidebarProjectChoice(
            id: "dpcode-website",
            label: "dpcode-website",
            iconSystemName: "laptopcomputer",
            projectPath: "/Users/demo/Developer/dpcode-website",
            sortDate: Date()
        ),
        SidebarProjectChoice(
            id: "openusage",
            label: "openusage",
            iconSystemName: "laptopcomputer",
            projectPath: "/Users/demo/Developer/openusage",
            sortDate: Date()
        ),
        SidebarProjectChoice(
            id: "Remodex",
            label: "Remodex",
            iconSystemName: "laptopcomputer",
            projectPath: "/Users/demo/Developer/Remodex",
            sortDate: Date()
        )
    ]
}

#Preview("Light") {
    Color.gray.opacity(0.15).ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            SidebarNewChatProjectPickerSheet(
                choices: SidebarNewChatProjectPickerSheetPreviewData.sampleChoices,
                onSelectProject: { _ in },
                onSelectWorktreeProject: { _ in },
                onSelectWithoutProject: {},
                onBrowseLocalFolder: {}
            )
        }
}

#Preview("Dark") {
    Color.gray.opacity(0.15).ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            SidebarNewChatProjectPickerSheet(
                choices: SidebarNewChatProjectPickerSheetPreviewData.sampleChoices,
                onSelectProject: { _ in },
                onSelectWorktreeProject: { _ in },
                onSelectWithoutProject: {},
                onBrowseLocalFolder: {}
            )
        }
        .preferredColorScheme(.dark)
}

#Preview("Empty") {
    Color.gray.opacity(0.15).ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            SidebarNewChatProjectPickerSheet(
                choices: [],
                onSelectProject: { _ in },
                onSelectWorktreeProject: { _ in },
                onSelectWithoutProject: {},
                onBrowseLocalFolder: {}
            )
        }
}
#endif
