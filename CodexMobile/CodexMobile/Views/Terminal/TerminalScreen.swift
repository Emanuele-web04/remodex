// FILE: TerminalScreen.swift
// Purpose: Full-page Ghostty SSH terminal route modeled after t3code-mobile's terminal screen.
// Layer: View
// Exports: TerminalScreen
// Depends on: CodexService, GhosttyTerminalSurface, RemodexTerminalModels

import Foundation
import SwiftUI
import UIKit

struct TerminalScreen: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.colorScheme) private var colorScheme
    @State private var draftProfile = RemodexTerminalProfileStore.load()
    @State private var connectionDraft = RemodexTerminalProfileStore.load().connectionString
    @State private var privateKeyDraft = RemodexTerminalPrivateKeyStore.loadPrivateKey()
    @State private var passphraseDraft = RemodexTerminalPrivateKeyStore.loadPassphrase()
    @State private var isShowingConnectionEditor = false
    @State private var activeTerminalId = CodexService.defaultTerminalId
    @State private var bootstrappedTerminalIds = Set<String>()
    @State private var userClosedTerminalIds = Set<String>()
    @State private var initialWorkingDirectoryByTerminalId: [String: String] = [:]
    @State private var isNativeTerminalAvailable = true
    @State private var actionErrorMessage: String?
    @State private var didApplyPreferredWorkingDirectory = false
    @State private var pendingModifier: TerminalPendingModifier?
    @State private var selectedModifier: TerminalPendingModifier = .ctrl
    @AppStorage("codex.terminal.fontSize") private var terminalFontSize = remodexTerminalDefaultFontSize

    let preferredWorkingDirectory: String?

    private var theme: RemodexTerminalTheme {
        RemodexTerminalTheme.resolved(for: colorScheme)
    }

    private var hostPlatform: TerminalHostPlatform {
        TerminalHostPlatform.infer(
            from: [
                codex.trustedPairPresentation?.systemName,
                codex.trustedPairPresentation?.name,
                draftProfile.displayTarget,
            ]
            .compactMap { $0 }
            .joined(separator: " ")
        )
    }

    private var profileResolvedFromConnection: RemodexTerminalProfile {
        var profile = draftProfile
        profile.applyConnectionString(connectionDraft)
        return profile.normalizedForSave
    }

    private var hasConnectionConfiguration: Bool {
        let profile = profileResolvedFromConnection
        return !profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && RemodexTerminalPrivateKeyStore.hasPrivateKey(privateKeyDraft)
    }

    private var isRunning: Bool {
        activeSnapshot.status == .running || activeSnapshot.status == .starting
    }

    private var terminalKey: String {
        "\(activeTerminalId):\(activeSnapshot.instanceId ?? "idle")"
    }

    private var activeSnapshot: RemodexTerminalSnapshot {
        codex.terminalSnapshot(for: activeTerminalId)
    }

    private var routeInitialWorkingDirectory: String? {
        let trimmed = preferredWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var currentWorkingDirectory: String {
        firstNonEmpty([
            activeSnapshot.cwd,
            initialWorkingDirectoryByTerminalId[activeTerminalId],
        ]) ?? ""
    }

    private var terminalHostTitle: String {
        firstNonEmpty([
            profileResolvedFromConnection.nickname,
            codex.trustedPairPresentation?.name,
            profileResolvedFromConnection.displayTarget,
        ]) ?? "Terminal"
    }

    private var navigationTopLine: String {
        let trimmed = terminalHostTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Terminal" : trimmed
    }

    // Keep the subtitle short and stable; long cwd/user-host strings are already
    // available through terminal context and tend to crowd the navigation bar.
    private var navigationBottomLine: String {
        if let project = projectDisplayName(for: currentWorkingDirectory),
           !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return project
        }
        return "Terminal"
    }

    private var statusLabel: String {
        switch activeSnapshot.status {
        case .running:
            return "Running"
        case .starting:
            return "Starting"
        case .error:
            return "Error"
        case .exited:
            return "Exited"
        case .closed:
            return "Closed"
        case .idle:
            return "Idle"
        }
    }

    private var terminalErrorDetail: String? {
        let value = actionErrorMessage ?? activeSnapshot.errorMessage
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var statusTone: TerminalStatusTone {
        switch activeSnapshot.status {
        case .running:
            return TerminalStatusTone(tint: "#34d399", text: "#a3a3a3")
        case .starting:
            return TerminalStatusTone(tint: "#f59e0b", text: "#a3a3a3")
        case .error:
            return TerminalStatusTone(tint: "#ef4444", text: "#fca5a5")
        case .idle, .closed, .exited:
            return TerminalStatusTone(tint: "#ef4444", text: "#a3a3a3")
        }
    }

    private var modifierClusterActions: [TerminalToolbarAction] {
        [
            TerminalToolbarAction(kind: .send("\u{1B}"), key: "esc", label: "esc"),
            TerminalToolbarAction(
                kind: .modifier(selectedModifier),
                key: "modifier-selector",
                label: selectedModifier.selectorLabel
            ),
            TerminalToolbarAction(kind: .send("\t"), key: "tab", label: "tab"),
        ]
    }

    private var symbolClusterActions: [TerminalToolbarAction] {
        [
            TerminalToolbarAction(kind: .send("~"), key: "tilde", label: "~"),
            TerminalToolbarAction(kind: .send("|"), key: "pipe", label: "|"),
            TerminalToolbarAction(kind: .send("/"), key: "slash", label: "/"),
        ]
    }

    // Keep the accessory rail to two well-fitted capsules (matches the
    // reference design in screenshot #2). A previous "extras" cluster with a
    // standalone `-` key got hard-clipped between the symbols capsule and the
    // keyboard-dismiss circle on standard-width iPhones, which is why the bar
    // read as "cut off". Dash is still easy to type from the system numpad.
    private var terminalToolbarClusters: [TerminalToolbarCluster] {
        [
            TerminalToolbarCluster(id: "modifiers", actions: modifierClusterActions),
            TerminalToolbarCluster(id: "symbols", actions: symbolClusterActions),
        ]
    }

    private var terminalMenuSessions: [TerminalMenuSessionItem] {
        var snapshots = codex.knownTerminalSnapshots()
        if !snapshots.contains(where: { $0.terminalId == activeTerminalId }) {
            snapshots.append(activeSnapshot)
        }

        return snapshots.filter { snapshot in
            snapshot.terminalId == activeTerminalId || snapshot.status.isRunning
        }.map { snapshot in
            TerminalMenuSessionItem(
                terminalId: snapshot.terminalId,
                displayLabel: terminalDisplayLabel(snapshot.terminalId),
                status: snapshot.status,
                cwd: snapshot.cwd
            )
        }
    }

    private var canPasteIntoActiveTerminal: Bool {
        activeSnapshot.status == .running && UIPasteboard.general.hasStrings
    }

    var body: some View {
        ZStack {
            Color(hexString: theme.background)
                .ignoresSafeArea()

            terminalRouteBody
        }
        .navigationBarTitleDisplayMode(.inline)
        // Use the system bar (translucent over the black terminal background) instead
        // of an opaque tinted bar so the native back button and status pill float on top.
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(colorScheme, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                TerminalRouteTitle(
                    topLine: navigationTopLine,
                    bottomLine: navigationBottomLine,
                    theme: theme
                )
            }
            ToolbarItem(placement: .topBarTrailing) {
                TerminalOptionsMenu(
                    statusLabel: statusLabel,
                    errorDetail: terminalErrorDetail,
                    statusTone: statusTone,
                    theme: theme,
                    fontSize: terminalFontSize,
                    sessions: terminalMenuSessions,
                    activeTerminalId: activeTerminalId,
                    isRunning: isRunning,
                    hasConnectionConfiguration: hasConnectionConfiguration,
                    canPaste: canPasteIntoActiveTerminal,
                    canClear: !activeSnapshot.bufferData.isEmpty,
                    canResetKnownHost: !profileResolvedFromConnection.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    onSelectSession: selectTerminalSession,
                    onOpenNewTerminal: openNewTerminalFromMenu,
                    onToggleConnection: toggleTerminalConnection,
                    onOpenConnectionEditor: showConnectionEditor,
                    onPaste: pasteIntoActiveTerminal,
                    onClear: clearTerminal,
                    onResetKnownHost: resetKnownHost,
                    onAdjustFontSize: adjustFontSize
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if hasConnectionConfiguration {
                TerminalRouteAccessoryBar(
                    clusters: terminalToolbarClusters,
                    pendingModifier: pendingModifier,
                    theme: theme,
                    isEnabled: activeSnapshot.status == .running,
                    onAction: handleToolbarActionPress,
                    onSelectModifier: selectModifier,
                    onDismissKeyboard: dismissSystemKeyboard,
                    onDirectionalInput: sendDirectionalInput
                )
            }
        }
        .sheet(isPresented: $isShowingConnectionEditor) {
            TerminalConnectionEditorSheet(
                profile: $draftProfile,
                connection: $connectionDraft,
                privateKey: $privateKeyDraft,
                passphrase: $passphraseDraft,
                canSave: hasConnectionConfiguration,
                onSave: {
                    Task { @MainActor in
                        await saveConnectionAndOpen()
                    }
                },
                onResetKnownHost: resetKnownHost
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .task(id: activeTerminalId) {
            await bootstrapTerminalRoute()
        }
        .onChange(of: preferredWorkingDirectory) { _, _ in
            didApplyPreferredWorkingDirectory = false
            applyPreferredWorkingDirectoryIfNeeded()
        }
    }

    @ViewBuilder
    private var terminalRouteBody: some View {
        if !hasConnectionConfiguration {
            TerminalRouteUnavailableView(
                title: "Terminal unavailable",
                detail: "SSH connection and key are required before opening a shell.",
                theme: theme,
                action: showConnectionEditor
            )
        } else {
            if isNativeTerminalAvailable {
                GhosttyTerminalSurface(
                    terminalKey: terminalKey,
                    buffer: activeSnapshot.bufferData,
                    fontSize: CGFloat(terminalFontSize),
                    colorScheme: colorScheme,
                    theme: theme,
                    onInput: handleTerminalDataInput,
                    onResize: resizeTerminal,
                    onNativeAvailabilityChanged: { isAvailable in
                        isNativeTerminalAvailable = isAvailable
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Keep a small vertical breathing room from the toolbar / accessory bar
                // but give the SSH output the full width; wide outputs like neofetch
                // were reading as cropped with the previous 8pt horizontal inset.
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            } else {
                TerminalFallbackSurface(
                    snapshot: activeSnapshot,
                    fontSize: CGFloat(terminalFontSize),
                    theme: theme,
                    isRunning: isRunning,
                    onInput: handleTerminalTextInput,
                    onResize: resizeTerminal
                )
            }
        }
    }

    private func bootstrapTerminalRoute() async {
        if restoreRunningTerminalIfNeeded() {
            return
        }
        applyPreferredWorkingDirectoryIfNeeded()
        connectionDraft = draftProfile.connectionString
        try? await codex.refreshTerminalSnapshot()

        guard hasConnectionConfiguration else {
            isShowingConnectionEditor = true
            return
        }
        guard !bootstrappedTerminalIds.contains(activeTerminalId),
              !userClosedTerminalIds.contains(activeTerminalId) else { return }
        guard !isRunning else {
            bootstrappedTerminalIds.insert(activeTerminalId)
            return
        }

        bootstrappedTerminalIds.insert(activeTerminalId)
        rememberRouteInitialWorkingDirectoryIfNeeded(for: activeTerminalId)
        await openTerminal()
    }

    private func restoreRunningTerminalIfNeeded() -> Bool {
        guard activeTerminalId == CodexService.defaultTerminalId else { return false }
        let runningSnapshots = codex.knownTerminalSnapshots().filter { $0.status.isRunning }
        guard let preferredSnapshot = runningSnapshots.first(where: { $0.terminalId == CodexService.defaultTerminalId })
            ?? runningSnapshots.first else {
            return false
        }
        guard preferredSnapshot.terminalId != activeTerminalId else {
            return false
        }
        activeTerminalId = preferredSnapshot.terminalId
        return true
    }

    private func selectTerminalSession(_ terminalId: String) {
        activeTerminalId = terminalId
    }

    private func openNewTerminalFromMenu() {
        Task { @MainActor in
            await openNewTerminal()
        }
    }

    private func toggleTerminalConnection() {
        Task { @MainActor in
            if isRunning {
                await closeTerminal()
            } else {
                userClosedTerminalIds.remove(activeTerminalId)
                await openTerminal()
            }
        }
    }

    private func showConnectionEditor() {
        isShowingConnectionEditor = true
    }

    private func saveConnectionAndOpen() async {
        isShowingConnectionEditor = false
        userClosedTerminalIds.remove(activeTerminalId)
        bootstrappedTerminalIds.insert(activeTerminalId)
        rememberRouteInitialWorkingDirectoryIfNeeded(for: activeTerminalId)
        await openTerminal()
    }

    private func openNewTerminal() async {
        let nextTerminalId = nextOpenTerminalId()
        activeTerminalId = nextTerminalId
        userClosedTerminalIds.remove(nextTerminalId)
        bootstrappedTerminalIds.insert(nextTerminalId)
        rememberRouteInitialWorkingDirectoryIfNeeded(for: nextTerminalId)
        actionErrorMessage = nil
        await openTerminal()
    }

    private func openTerminal() async {
        var connectionProfile = profileResolvedFromConnection
        connectionProfile.cwd = ""
        draftProfile = connectionProfile
        guard hasConnectionConfiguration else {
            isShowingConnectionEditor = true
            return
        }

        actionErrorMessage = nil
        RemodexTerminalProfileStore.save(connectionProfile)
        RemodexTerminalPrivateKeyStore.savePrivateKey(privateKeyDraft)
        RemodexTerminalPrivateKeyStore.savePassphrase(passphraseDraft)

        var sessionProfile = connectionProfile
        sessionProfile.cwd = initialWorkingDirectoryByTerminalId[activeTerminalId] ?? ""
        do {
            try await codex.openTerminal(
                terminalId: activeTerminalId,
                profile: sessionProfile,
                cols: activeSnapshot.cols,
                rows: activeSnapshot.rows
            )
        } catch {
            actionErrorMessage = terminalErrorText(error)
        }
    }

    private func closeTerminal() async {
        userClosedTerminalIds.insert(activeTerminalId)
        actionErrorMessage = nil
        do {
            try await codex.closeTerminal(terminalId: activeTerminalId)
        } catch {
            actionErrorMessage = terminalErrorText(error)
        }
    }

    private func resetKnownHost() {
        let profile = profileResolvedFromConnection.normalizedForSave
        guard !profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        RemodexSSHKnownHostStore.delete(host: profile.host, port: profile.port)
        actionErrorMessage = nil
    }

    private func clearTerminal() {
        actionErrorMessage = nil
        Task { @MainActor in
            do {
                try await codex.clearTerminalBuffer(terminalId: activeTerminalId)
            } catch {
                actionErrorMessage = terminalErrorText(error)
            }
        }
    }

    private func pasteIntoActiveTerminal() {
        guard activeSnapshot.status == .running,
              let pasteText = UIPasteboard.general.string,
              !pasteText.isEmpty else { return }

        pendingModifier = nil
        writeInputChunks(Self.terminalPasteInputChunks(
            for: pasteText,
            bracketedPasteEnabled: activeSnapshot.bracketedPasteEnabled
        ))
    }

    private func applyPreferredWorkingDirectoryIfNeeded() {
        guard !didApplyPreferredWorkingDirectory else { return }
        didApplyPreferredWorkingDirectory = true
        guard let trimmedCWD = routeInitialWorkingDirectory,
              activeSnapshot.status == .running,
              activeSnapshot.cwd != trimmedCWD else {
            return
        }
        initialWorkingDirectoryByTerminalId[activeTerminalId] = trimmedCWD
        Task { @MainActor in
            do {
                try await codex.changeTerminalWorkingDirectory(trimmedCWD, terminalId: activeTerminalId)
            } catch {
                actionErrorMessage = terminalErrorText(error)
            }
        }
    }

    private func rememberRouteInitialWorkingDirectoryIfNeeded(for terminalId: String) {
        guard let routeInitialWorkingDirectory,
              initialWorkingDirectoryByTerminalId[terminalId] == nil else {
            return
        }
        initialWorkingDirectoryByTerminalId[terminalId] = routeInitialWorkingDirectory
    }

    private func handleTerminalDataInput(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let text = String(data: data, encoding: .utf8) else {
            writeInput(data)
            return
        }
        handleTerminalTextInput(text)
    }

    private func handleTerminalTextInput(_ text: String) {
        guard !text.isEmpty else { return }

        let outputText: String
        switch pendingModifier {
        case .cmd, .alt:
            pendingModifier = nil
            outputText = "\u{1B}\(text)"
        case .shift:
            pendingModifier = nil
            outputText = text
        case .ctrl:
            pendingModifier = nil
            outputText = Self.applyCtrlModifier(text)
        case nil:
            outputText = text
        }

        writeInput(Data(outputText.utf8))
    }

    private func handleToolbarActionPress(_ action: TerminalToolbarAction) {
        switch action.kind {
        case .modifier(let modifier):
            pendingModifier = pendingModifier == modifier ? nil : modifier
        case .send(let data):
            handleTerminalTextInput(data)
        }
    }

    private func selectModifier(_ modifier: TerminalPendingModifier) {
        selectedModifier = modifier
        pendingModifier = modifier
    }

    // Project-wide pattern (see ContentView.swift:985): nil-target resignFirstResponder
    // walks the responder chain so we don't need a reference to the offscreen UITextField
    // that GhosttyTerminalView uses as its first responder.
    private func dismissSystemKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func sendDirectionalInput(_ text: String) {
        guard !text.isEmpty else { return }
        let outputText: String
        if let modifier = pendingModifier,
           let modifiedArrow = Self.modifiedArrowSequence(text, modifier: modifier) {
            pendingModifier = nil
            outputText = modifiedArrow
        } else {
            outputText = text
        }
        writeInput(Data(outputText.utf8))
    }

    private func writeInput(_ data: Data) {
        guard activeSnapshot.status == .running else { return }
        let terminalId = activeTerminalId
        Task { @MainActor in
            try? await codex.writeTerminalInput(data, terminalId: terminalId)
        }
    }

    private func writeInputChunks(_ chunks: [Data]) {
        guard activeSnapshot.status == .running, !chunks.isEmpty else { return }
        let terminalId = activeTerminalId
        Task { @MainActor in
            for chunk in chunks where !chunk.isEmpty {
                try? await codex.writeTerminalInput(chunk, terminalId: terminalId)
            }
        }
    }

    private func resizeTerminal(cols: Int, rows: Int) {
        Task { @MainActor in
            try? await codex.resizeTerminal(terminalId: activeTerminalId, cols: cols, rows: rows)
        }
    }

    private func adjustFontSize(_ delta: Double) {
        terminalFontSize = min(
            remodexTerminalMaxFontSize,
            max(remodexTerminalMinFontSize, terminalFontSize + delta)
        )
    }

    private func terminalErrorText(_ error: Error) -> String {
        if case CodexServiceError.rpcError(let rpcError) = error {
            return rpcError.message
        }
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return RemodexNativeSSHTerminalError.userFacingDescription(for: error)
    }

    private func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private func projectDisplayName(for path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    private func terminalDisplayLabel(_ terminalId: String) -> String {
        let index = terminalIndex(terminalId)
        guard index > 1 else { return "Terminal" }
        return "Terminal \(index)"
    }

    private func nextOpenTerminalId() -> String {
        let existingIndexes = terminalMenuSessions.map { terminalIndex($0.terminalId) }
        let nextIndex = (existingIndexes.max() ?? 0) + 1
        return "term-\(max(1, nextIndex))"
    }

    private func terminalIndex(_ terminalId: String) -> Int {
        guard terminalId.hasPrefix("term-"),
              let value = Int(terminalId.dropFirst(5)) else {
            return 1
        }
        return value
    }

    // Only the first character is modified by Ctrl; the rest of the chunk is
    // passed through verbatim. Without preserving the tail, a paste or
    // autocomplete arriving while Ctrl was armed would drop everything past
    // the first character.
    private static func applyCtrlModifier(_ input: String) -> String {
        guard let firstCharacter = input.first else {
            return input
        }

        let tail = String(input.dropFirst())

        let lowerCharacter = Character(firstCharacter.lowercased())
        if let scalar = lowerCharacter.unicodeScalars.first,
           lowerCharacter >= "a",
           lowerCharacter <= "z" {
            let modified = String(UnicodeScalar(scalar.value - 96) ?? scalar)
            return modified + tail
        }

        let modified: String
        switch firstCharacter {
        case "@": modified = "\u{0}"
        case "[": modified = "\u{1B}"
        case "\\": modified = "\u{1C}"
        case "]": modified = "\u{1D}"
        case "^": modified = "\u{1E}"
        case "_": modified = "\u{1F}"
        case "?": modified = "\u{7F}"
        default: return input
        }
        return modified + tail
    }

    private static func modifiedArrowSequence(_ input: String, modifier: TerminalPendingModifier) -> String? {
        guard input.hasPrefix("\u{1B}[") else { return nil }
        guard let final = input.last, ["A", "B", "C", "D"].contains(final) else { return nil }
        return "\u{1B}[1;\(modifier.csiModifierParameter)\(final)"
    }

    static func terminalPasteInputChunks(
        for text: String,
        bracketedPasteEnabled: Bool,
        maxChunkBytes: Int = 8_192
    ) -> [Data] {
        let normalizedText = normalizedTerminalPasteText(text)
        let wrappedText = bracketedPasteEnabled
            ? "\u{1B}[200~\(normalizedText)\u{1B}[201~"
            : normalizedText

        return Data(wrappedText.utf8).terminalPasteChunks(maxChunkBytes: maxChunkBytes)
    }

    private static func normalizedTerminalPasteText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
            .replacingOccurrences(of: "\u{0}", with: "")
            // Strip embedded bracketed-paste delimiters so clipboard content cannot
            // prematurely close the wrapper and turn the rest into typed commands.
            .replacingOccurrences(of: "\u{1B}[200~", with: "")
            .replacingOccurrences(of: "\u{1B}[201~", with: "")
    }
}

private extension Data {
    func terminalPasteChunks(maxChunkBytes: Int) -> [Data] {
        guard !isEmpty else { return [] }
        let safeChunkSize = Swift.max(1, maxChunkBytes)
        guard count > safeChunkSize else { return [self] }

        var chunks: [Data] = []
        chunks.reserveCapacity((count + safeChunkSize - 1) / safeChunkSize)

        var offset = 0
        while offset < count {
            let end = Swift.min(offset + safeChunkSize, count)
            chunks.append(subdata(in: offset..<end))
            offset = end
        }

        return chunks
    }
}
