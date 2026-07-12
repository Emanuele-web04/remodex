// FILE: QueuedDraftsPanel.swift
// Purpose: Displays queued message drafts as a compact carousel capsule that opens a sheet with steer/delete controls.
// Layer: View Component
// Exports: QueuedDraftsPanel, QueuedStatusCapsule, QueuedDraftsSheet
// Depends on: SwiftUI, QueuedTurnDraft, AppFont, HapticFeedback, GlassStatusPill

import SwiftUI

/// Compact carousel capsule summarizing queued follow-ups next to the plan pill.
struct QueuedStatusCapsule: View {
    let count: Int
    let onTap: () -> Void

    var body: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            onTap()
        } label: {
            GlassStatusPill {
                Text("Queued")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)

                Text("\(count)")
                    .font(AppFont.caption())
                    .foregroundStyle(.primary.opacity(0.78))
                    .fixedSize()
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Queued messages")
        .accessibilityValue("\(count)")
        .accessibilityHint("Shows the queued follow-ups in a sheet")
    }
}

/// Sheet presentation of the queued drafts with the full restore/steer/delete controls.
struct QueuedDraftsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let drafts: [QueuedTurnDraft]
    let canSteerDrafts: Bool
    let canRestoreDrafts: Bool
    let steeringDraftID: String?
    let onRestore: (String) -> Void
    let onSteer: (String) -> Void
    let onRemove: (String) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                QueuedDraftsPanel(
                    drafts: drafts,
                    canSteerDrafts: canSteerDrafts,
                    canRestoreDrafts: canRestoreDrafts,
                    steeringDraftID: steeringDraftID,
                    onRestore: onRestore,
                    onSteer: onSteer,
                    onRemove: onRemove,
                    rowHeight: 44
                )
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }
            .background(Color(.systemBackground))
            .navigationTitle("Queued")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct QueuedDraftsPanel: View {
    let drafts: [QueuedTurnDraft]
    let canSteerDrafts: Bool
    let canRestoreDrafts: Bool
    let steeringDraftID: String?
    let onRestore: (String) -> Void
    let onSteer: (String) -> Void
    let onRemove: (String) -> Void
    var rowHeight: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(drafts) { draft in
                HStack(spacing: 8) {
                    RemodexIcon.image(systemName: "return.right")
                        .font(AppFont.system(size: 10, weight: .regular))
                        .foregroundStyle(.tertiary)

                    Text(draft.text)
                        .font(AppFont.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    // Pulls one queued row back into the composer for manual editing.
                    Button {
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        onRestore(draft.id)
                    } label: {
                        RemodexIcon.image(systemName: "arrow.down")
                            .font(AppFont.system(size: 12, weight: .medium))
                            .foregroundStyle(canRestoreDrafts ? .primary : .tertiary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                            .background(
                                Circle()
                                    .fill(.regularMaterial)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canRestoreDrafts)
                    .accessibilityLabel("Move draft into input")

                    if canSteerDrafts {
                        Button {
                            HapticFeedback.shared.triggerImpactFeedback(style: .light)
                            onSteer(draft.id)
                        } label: {
                            Text("Steer")
                                .font(AppFont.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .contentShape(Rectangle())
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(.regularMaterial)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(steeringDraftID != nil)
                    }

                    Button {
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        onRemove(draft.id)
                    } label: {
                        RemodexIcon.image(systemName: "trash")
                            .font(AppFont.system(size: 13, weight: .regular))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(steeringDraftID == draft.id)
                }
                .padding(.horizontal, 10)
                .frame(height: rowHeight)

                if draft.id != drafts.last?.id {
                    Divider()
                        .padding(.horizontal, 16)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Queued Draft Row") {
    QueuedDraftsPanel(
        drafts: [
            QueuedTurnDraft(
                id: "draft-1",
                text: "Refine the active run to focus only on failing tests first",
                attachments: [],
                skillMentions: [],
                collaborationMode: nil,
                createdAt: .now
            ),
            QueuedTurnDraft(
                id: "draft-2",
                text: "Then summarize the regression risk in the networking layer",
                attachments: [],
                skillMentions: [],
                collaborationMode: nil,
                createdAt: .now
            ),
        ],
        canSteerDrafts: true,
        canRestoreDrafts: true,
        steeringDraftID: nil,
        onRestore: { _ in },
        onSteer: { _ in },
        onRemove: { _ in }
    )
}

#Preview("Queued Draft Row - Steering") {
    QueuedDraftsPanel(
        drafts: [
            QueuedTurnDraft(
                id: "draft-1",
                text: "Refine the active run to focus only on failing tests first",
                attachments: [],
                skillMentions: [],
                collaborationMode: nil,
                createdAt: .now
            ),
            QueuedTurnDraft(
                id: "draft-2",
                text: "Then summarize the regression risk in the networking layer",
                attachments: [],
                skillMentions: [],
                collaborationMode: nil,
                createdAt: .now
            ),
        ],
        canSteerDrafts: true,
        canRestoreDrafts: false,
        steeringDraftID: "draft-1",
        onRestore: { _ in },
        onSteer: { _ in },
        onRemove: { _ in }
    )
}
