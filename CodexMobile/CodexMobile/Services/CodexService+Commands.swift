// FILE: CodexService+Commands.swift
// Purpose: Fetches and caches local slash commands from the bridge.
// Layer: Service
// Exports: CodexService command helpers
// Depends on: CodexSlashCommand, RPCMessage

import Foundation

extension CodexService {
    func refreshSlashCommandsIfNeeded(minInterval: TimeInterval = 10) {
        if isLoadingSlashCommands {
            return
        }

        if let lastRefresh = lastSlashCommandsRefreshAt,
           Date().timeIntervalSince(lastRefresh) < minInterval,
           !slashCommands.isEmpty {
            return
        }

        Task {
            await refreshSlashCommands()
        }
    }

    func refreshSlashCommands() async {
        if isLoadingSlashCommands {
            return
        }

        isLoadingSlashCommands = true
        defer { isLoadingSlashCommands = false }

        do {
            let response = try await sendRequest(method: "commands/list", params: .object([:]))
            guard let decoded = decodeSlashCommands(from: response.result) else {
                throw CodexServiceError.invalidResponse("commands/list response missing result.commands")
            }

            let normalized = decoded
                .map { command in
                    CodexSlashCommand(
                        token: command.normalizedToken,
                        title: command.title.trimmingCharacters(in: .whitespacesAndNewlines),
                        subtitle: command.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                        symbolName: command.symbolName?.trimmingCharacters(in: .whitespacesAndNewlines),
                        content: command.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                        argumentHint: command.argumentHint?.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
                .filter { !$0.title.isEmpty && !$0.normalizedToken.isEmpty }

            let deduped = Dictionary(grouping: normalized) { $0.normalizedToken.lowercased() }
                .compactMap { _, bucket in bucket.first }
                .sorted { lhs, rhs in
                    lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }

            slashCommands = deduped
            slashCommandsErrorMessage = nil
            lastSlashCommandsRefreshAt = Date()
        } catch {
            slashCommands = []
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            slashCommandsErrorMessage = message.isEmpty ? "Unable to load commands" : message
        }
    }
}

private extension CodexService {
    func decodeSlashCommands(from result: JSONValue?) -> [CodexSlashCommand]? {
        guard let resultObject = result?.objectValue,
              let commandsValue = resultObject["commands"] else {
            return nil
        }

        return decodeModel([CodexSlashCommand].self, from: commandsValue)
    }
}
