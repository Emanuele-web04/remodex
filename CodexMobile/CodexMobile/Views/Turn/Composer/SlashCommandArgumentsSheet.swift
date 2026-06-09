// FILE: SlashCommandArgumentsSheet.swift
// Purpose: Collects structured slash-command arguments and submits command/execute (PR5b).
// Layer: View Component
// Exports: SlashCommandArgumentsSheet
// Depends on: SwiftUI, BridgeSlashCommand

import SwiftUI

struct SlashCommandArgumentsSheet: View {
    let command: BridgeSlashCommand
    let supportsExecute: Bool
    let onSubmit: ([BridgeSlashCommandArgumentField]) -> Void
    let onDismiss: () -> Void

    @State private var fieldValues: [String: String] = [:]
    @State private var fieldErrors: [String: String] = [:]
    @State private var submitError: String?

    private var fieldSpecs: [SlashCommandArgumentFieldSpec] {
        command.argumentFieldSpecs
    }

    var body: some View {
        NavigationStack {
            Form {
                if !command.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section {
                        Text(command.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Arguments") {
                    if fieldSpecs.isEmpty {
                        Text("No argument fields are configured for this command.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(fieldSpecs) { spec in
                            argumentFieldView(for: spec)
                        }
                    }
                }

                if let submitError, !submitError.isEmpty {
                    Section {
                        Text(submitError)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(command.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onDismiss)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Run", action: submit)
                        .disabled(!supportsExecute || fieldSpecs.isEmpty)
                }
            }
            .onAppear(perform: seedFieldValuesIfNeeded)
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func argumentFieldView(for spec: SlashCommandArgumentFieldSpec) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if spec.isMultiline {
                TextEditor(text: binding(for: spec.id))
                    .frame(minHeight: 120)
            } else {
                TextField(spec.label, text: binding(for: spec.id))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if let error = fieldErrors[spec.id], !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { fieldValues[key, default: ""] },
            set: { newValue in
                fieldValues[key] = newValue
                if fieldErrors[key] != nil {
                    fieldErrors[key] = nil
                }
                submitError = nil
            }
        )
    }

    private func seedFieldValuesIfNeeded() {
        guard fieldValues.isEmpty else { return }
        var seeded: [String: String] = [:]
        for spec in fieldSpecs {
            seeded[spec.id] = ""
        }
        fieldValues = seeded
    }

    private func submit() {
        submitError = nil
        var nextErrors: [String: String] = [:]
        var payload: [BridgeSlashCommandArgumentField] = []

        for spec in fieldSpecs {
            let trimmed = fieldValues[spec.id, default: ""]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                nextErrors[spec.id] = "Required"
                continue
            }
            payload.append(BridgeSlashCommandArgumentField(key: spec.id, value: trimmed))
        }

        fieldErrors = nextErrors
        guard nextErrors.isEmpty else { return }
        onSubmit(payload)
    }
}