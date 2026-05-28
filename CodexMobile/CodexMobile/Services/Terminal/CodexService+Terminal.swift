// FILE: CodexService+Terminal.swift
// Purpose: Starts and controls the on-device SSH terminal session.
// Layer: Service Extension
// Exports: CodexService terminal APIs
// Depends on: CodexService, RemodexNativeSSHTerminal, RemodexTerminalModels

import Foundation

extension CodexService {
    static let defaultTerminalId = "term-1"

    func terminalSnapshot(for terminalId: String) -> RemodexTerminalSnapshot {
        if terminalId == Self.defaultTerminalId, terminalSnapshotsById[terminalId] == nil {
            return terminalSnapshot
        }
        return terminalSnapshotsById[terminalId] ?? RemodexTerminalSnapshot.idleSnapshot(terminalId: terminalId)
    }

    func knownTerminalSnapshots() -> [RemodexTerminalSnapshot] {
        var snapshots = terminalSnapshotsById
        snapshots[Self.defaultTerminalId] = snapshots[Self.defaultTerminalId] ?? terminalSnapshot
        return snapshots.values.sorted { lhs, rhs in
            terminalSortIndex(lhs.terminalId) < terminalSortIndex(rhs.terminalId)
        }
    }

    func openTerminal(
        profile: RemodexTerminalProfile,
        cols: Int,
        rows: Int
    ) async throws {
        try await openTerminal(
            terminalId: Self.defaultTerminalId,
            profile: profile,
            cols: cols,
            rows: rows
        )
    }

    func openTerminal(
        terminalId: String,
        profile: RemodexTerminalProfile,
        cols: Int,
        rows: Int
    ) async throws {
        let normalizedProfile = profile.normalizedForSave
        var profileForSave = normalizedProfile
        profileForSave.cwd = ""
        let instanceId = UUID().uuidString
        let terminal = nativeTerminal(for: terminalId)
        terminalProfile = profileForSave
        RemodexTerminalProfileStore.save(profileForSave)
        setTerminalSnapshot(RemodexTerminalSnapshot(
            terminalId: terminalId,
            instanceId: instanceId,
            status: .starting,
            buffer: "",
            bufferData: Data(),
            cwd: normalizedProfile.cwd,
            cols: cols,
            rows: rows,
            errorMessage: nil,
            resizeSupported: true
        ), for: terminalId)

        let privateKey = RemodexTerminalPrivateKeyStore.loadPrivateKey()
        let passphrase = RemodexTerminalPrivateKeyStore.loadPassphrase()
        do {
            try await terminal.open(
                profile: normalizedProfile,
                privateKey: privateKey,
                passphrase: passphrase,
                cols: cols,
                rows: rows,
                onConnected: { [weak self] _ in
                    guard let self else { return }
                    guard self.isCurrentTerminalInstance(instanceId, terminalId: terminalId) else { return }
                    self.updateTerminalSnapshot(for: terminalId) { snapshot in
                        snapshot.status = .running
                        snapshot.errorMessage = nil
                        snapshot.resizeSupported = true
                    }
                    self.applyConnectedTerminalSizeAndDirectory(
                        instanceId: instanceId,
                        terminalId: terminalId,
                        cwd: normalizedProfile.cwd
                    )
                },
                onOutput: { [weak self] data in
                    guard self?.isCurrentTerminalInstance(instanceId, terminalId: terminalId) == true else { return }
                    self?.updateTerminalSnapshot(for: terminalId) { snapshot in
                        snapshot.appendOutput(data)
                    }
                },
                onFinished: { [weak self] error in
                    guard let self else { return }
                    guard self.isCurrentTerminalInstance(instanceId, terminalId: terminalId) else { return }
                    if let error {
                        self.updateTerminalSnapshot(for: terminalId) { snapshot in
                            snapshot.status = .error
                            snapshot.errorMessage = self.terminalErrorText(error)
                        }
                    } else {
                        self.updateTerminalSnapshot(for: terminalId) { snapshot in
                            if snapshot.status == .running || snapshot.status == .starting {
                                snapshot.status = .exited
                            }
                        }
                    }
                }
            )
        } catch {
            if isCurrentTerminalInstance(instanceId, terminalId: terminalId) {
                updateTerminalSnapshot(for: terminalId) { snapshot in
                    snapshot.status = .error
                    snapshot.errorMessage = terminalErrorText(error)
                }
            }
            throw error
        }
    }

    func writeTerminalInput(_ data: Data) async throws {
        try await writeTerminalInput(data, terminalId: Self.defaultTerminalId)
    }

    func writeTerminalInput(_ data: Data, terminalId: String) async throws {
        guard !data.isEmpty else { return }
        try await nativeTerminal(for: terminalId).write(data)
    }

    func writeTerminalInput(_ text: String) async throws {
        try await writeTerminalInput(Data(text.utf8))
    }

    func resizeTerminal(cols: Int, rows: Int) async throws {
        try await resizeTerminal(terminalId: Self.defaultTerminalId, cols: cols, rows: rows)
    }

    func resizeTerminal(terminalId: String, cols: Int, rows: Int) async throws {
        updateTerminalSnapshot(for: terminalId) { snapshot in
            snapshot.cols = cols
            snapshot.rows = rows
        }
        guard terminalSnapshot(for: terminalId).status == .running else { return }
        try await nativeTerminal(for: terminalId).resize(cols: cols, rows: rows)
    }

    func clearTerminalBuffer() async throws {
        try await clearTerminalBuffer(terminalId: Self.defaultTerminalId)
    }

    func clearTerminalBuffer(terminalId: String) async throws {
        updateTerminalSnapshot(for: terminalId) { snapshot in
            snapshot.buffer = ""
            snapshot.bufferData = Data()
        }
    }

    func changeTerminalWorkingDirectory(_ cwd: String) async throws {
        try await changeTerminalWorkingDirectory(cwd, terminalId: Self.defaultTerminalId)
    }

    func changeTerminalWorkingDirectory(_ cwd: String, terminalId: String) async throws {
        let trimmedCWD = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCWD.isEmpty else { return }
        updateTerminalSnapshot(for: terminalId) { snapshot in
            snapshot.cwd = trimmedCWD
        }
        guard terminalSnapshot(for: terminalId).status == .running else { return }
        try await writeTerminalInput(
            Data(shellChangeDirectoryCommand(for: trimmedCWD).utf8),
            terminalId: terminalId
        )
    }

    func closeTerminal() async throws {
        try await closeTerminal(terminalId: Self.defaultTerminalId)
    }

    func closeTerminal(terminalId: String) async throws {
        await nativeTerminal(for: terminalId).close()
        updateTerminalSnapshot(for: terminalId) { snapshot in
            snapshot.status = .closed
            snapshot.errorMessage = nil
        }
    }

    func refreshTerminalSnapshot() async throws {
        // The native SSH session is already the source of truth; no bridge RPC is needed.
    }

    func handleTerminalEvent(_ paramsObject: IncomingParamsObject?) {
        // Kept for compatibility with older bridges that might still emit terminal/event.
    }

    private func sendInitialTerminalDirectoryCommandIfNeeded(_ cwd: String, terminalId: String) async {
        let trimmedCWD = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCWD.isEmpty else { return }
        try? await writeTerminalInput(
            Data(shellChangeDirectoryCommand(for: trimmedCWD).utf8),
            terminalId: terminalId
        )
    }

    private func applyConnectedTerminalSizeAndDirectory(instanceId: String, terminalId: String, cwd: String) {
        Task { @MainActor in
            guard isCurrentTerminalInstance(instanceId, terminalId: terminalId) else { return }
            // The surface may have measured its real grid while SSH was still connecting.
            let snapshot = terminalSnapshot(for: terminalId)
            try? await nativeTerminal(for: terminalId).resize(cols: snapshot.cols, rows: snapshot.rows)
            guard isCurrentTerminalInstance(instanceId, terminalId: terminalId) else { return }
            await sendInitialTerminalDirectoryCommandIfNeeded(cwd, terminalId: terminalId)
        }
    }

    private func isCurrentTerminalInstance(_ instanceId: String, terminalId: String) -> Bool {
        terminalSnapshot(for: terminalId).instanceId == instanceId
    }

    private func nativeTerminal(for terminalId: String) -> RemodexNativeSSHTerminal {
        if terminalId == Self.defaultTerminalId {
            return nativeSSHTerminal
        }
        if let terminal = nativeSSHTerminalsById[terminalId] {
            return terminal
        }
        let terminal = RemodexNativeSSHTerminal()
        nativeSSHTerminalsById[terminalId] = terminal
        return terminal
    }

    private func setTerminalSnapshot(_ snapshot: RemodexTerminalSnapshot, for terminalId: String) {
        terminalSnapshotsById[terminalId] = snapshot
        if terminalId == Self.defaultTerminalId {
            terminalSnapshot = snapshot
        }
    }

    private func updateTerminalSnapshot(
        for terminalId: String,
        mutate: (inout RemodexTerminalSnapshot) -> Void
    ) {
        var snapshot = terminalSnapshot(for: terminalId)
        mutate(&snapshot)
        setTerminalSnapshot(snapshot, for: terminalId)
    }

    private func terminalSortIndex(_ terminalId: String) -> Int {
        guard terminalId.hasPrefix("term-"),
              let value = Int(terminalId.dropFirst(5)) else {
            return Int.max
        }
        return value
    }

    private func shellChangeDirectoryCommand(for cwd: String) -> String {
        "cd \(shellSingleQuoted(cwd))\n"
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func terminalErrorText(_ error: Error) -> String {
        RemodexNativeSSHTerminalError.userFacingDescription(for: error)
    }
}
