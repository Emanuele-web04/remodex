// FILE: RemodexNativeSSHTerminal.swift
// Purpose: Owns the phone-side SSH client and bridges raw TTY bytes to Ghostty.
// Layer: Service
// Exports: RemodexNativeSSHTerminal, RemodexNativeSSHTerminalError
// Depends on: Citadel, Crypto, Foundation, NIOCore

import Citadel
import Crypto
import Foundation
import NIO
import NIOCore
import NIOSSH

enum RemodexNativeSSHTerminalError: LocalizedError {
    case missingPrivateKey
    case hostKeyChanged
    case unsupportedPrivateKey(String)
    case sessionNotRunning

    var errorDescription: String? {
        switch self {
        case .missingPrivateKey:
            return "Paste your SSH private key before connecting."
        case .hostKeyChanged:
            return "The SSH host key changed. Check the host before reconnecting."
        case .unsupportedPrivateKey(let keyType):
            return "This SSH key type is not supported yet: \(keyType). Use an Ed25519 or RSA private key."
        case .sessionNotRunning:
            return "The SSH terminal is not running."
        }
    }
}

@MainActor
final class RemodexNativeSSHTerminal {
    private var client: SSHClient?
    private var writer: TTYStdinWriter?
    private var sessionTask: Task<Void, Never>?
    // Guards shared state so late callbacks from an older SSH task cannot affect a new session.
    private var currentSessionId: UUID?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var isUserClosing = false

    var isRunning: Bool {
        sessionTask != nil
    }

    func open(
        profile: RemodexTerminalProfile,
        privateKey: String,
        passphrase: String,
        cols: Int,
        rows: Int,
        onConnected: @escaping @MainActor (TTYStdinWriter) -> Void,
        onOutput: @escaping @MainActor (Data) -> Void,
        onFinished: @escaping @MainActor (Error?) -> Void
    ) async throws {
        let oldClient = client
        closeLocalState(markUserClosing: true)
        try? await oldClient?.close()
        isUserClosing = false
        let sessionId = UUID()
        let authenticationMethod = try Self.authenticationMethod(
            username: profile.username,
            privateKey: privateKey,
            passphrase: passphrase
        )

        try await withCheckedThrowingContinuation { continuation in
            currentSessionId = sessionId
            connectContinuation = continuation
            sessionTask = Task { [weak self] in
                var connectedClient: SSHClient?
                do {
                    let sshClient = try await SSHClient.connect(
                        host: profile.host,
                        port: profile.port,
                        authenticationMethod: authenticationMethod,
                        hostKeyValidator: .custom(RemodexSSHKnownHostValidator(
                            host: profile.host,
                            port: profile.port
                        )),
                        reconnect: .never
                    )
                    connectedClient = sshClient
                    let shouldCloseClient = await MainActor.run { () -> Bool in
                        guard let self, self.isCurrentSession(sessionId) else {
                            return true
                        }
                        self.client = sshClient
                        return false
                    }
                    if shouldCloseClient {
                        try? await sshClient.close()
                        return
                    }

                    try await sshClient.withPTY(
                        .init(
                            wantReply: true,
                            term: "xterm-256color",
                            terminalCharacterWidth: max(cols, 1),
                            terminalRowHeight: max(rows, 1),
                            terminalPixelWidth: 0,
                            terminalPixelHeight: 0,
                            terminalModes: .init([.ECHO: 1])
                        )
                    ) { inbound, outbound in
                        try await outbound.changeSize(
                            cols: cols,
                            rows: rows,
                            pixelWidth: 0,
                            pixelHeight: 0
                        )
                        await MainActor.run {
                            guard let self, self.isCurrentSession(sessionId) else { return }
                            self.writer = outbound
                            onConnected(outbound)
                            self.resumeConnectContinuation(for: sessionId)
                        }

                        for try await output in inbound {
                            switch output {
                            case .stdout(let buffer), .stderr(let buffer):
                                let data = Data(buffer.readableBytesView)
                                await MainActor.run {
                                    guard self?.isCurrentSession(sessionId) == true else { return }
                                    onOutput(data)
                                }
                            }
                        }
                    }
                    try? await sshClient.close()

                    await MainActor.run {
                        guard let self, self.isCurrentSession(sessionId) else { return }
                        self.clearSessionReferences(for: sessionId)
                        onFinished(nil)
                    }
                } catch {
                    if let connectedClient {
                        try? await connectedClient.close()
                    }
                    await MainActor.run {
                        guard let self, self.isCurrentSession(sessionId) else { return }
                        let wasUserClosing = self.isUserClosing || error is CancellationError
                        self.resumeConnectContinuation(for: sessionId, throwing: error)
                        self.clearSessionReferences(for: sessionId)
                        onFinished(wasUserClosing ? nil : error)
                    }
                }
            }
        }
    }

    func write(_ data: Data) async throws {
        guard let writer else {
            throw RemodexNativeSSHTerminalError.sessionNotRunning
        }
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await writer.write(buffer)
    }

    func resize(cols: Int, rows: Int) async throws {
        guard let writer else { return }
        try await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
    }

    func close() async {
        let client = client
        closeLocalState(markUserClosing: true)
        try? await client?.close()
    }

    private func closeLocalState(markUserClosing: Bool = false) {
        isUserClosing = markUserClosing
        sessionTask?.cancel()
        sessionTask = nil
        currentSessionId = nil
        writer = nil
        client = nil
        if markUserClosing {
            resumeConnectContinuation()
        } else {
            resumeConnectContinuation(throwing: CancellationError())
        }
    }

    private func clearSessionReferences(for sessionId: UUID) {
        guard isCurrentSession(sessionId) else { return }
        sessionTask = nil
        currentSessionId = nil
        writer = nil
        client = nil
    }

    private func isCurrentSession(_ sessionId: UUID) -> Bool {
        currentSessionId == sessionId
    }

    private func resumeConnectContinuation(for sessionId: UUID) {
        guard isCurrentSession(sessionId) else { return }
        resumeConnectContinuation()
    }

    private func resumeConnectContinuation() {
        connectContinuation?.resume()
        connectContinuation = nil
    }

    private func resumeConnectContinuation(throwing error: Error) {
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
    }

    private func resumeConnectContinuation(for sessionId: UUID, throwing error: Error) {
        guard isCurrentSession(sessionId) else { return }
        resumeConnectContinuation(throwing: error)
    }

    private static func authenticationMethod(
        username: String,
        privateKey: String,
        passphrase: String
    ) throws -> SSHAuthenticationMethod {
        let normalizedKey = privateKey
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            throw RemodexNativeSSHTerminalError.missingPrivateKey
        }

        let decryptionKey = passphrase.isEmpty ? nil : Data(passphrase.utf8)
        let keyType = try SSHKeyDetection.detectPrivateKeyType(from: normalizedKey)
        switch keyType {
        case .ed25519:
            let key = try Curve25519.Signing.PrivateKey(
                sshEd25519: normalizedKey,
                decryptionKey: decryptionKey
            )
            return .ed25519(username: username, privateKey: key)
        case .rsa:
            let key = try Insecure.RSA.PrivateKey(
                sshRsa: normalizedKey,
                decryptionKey: decryptionKey
            )
            return .rsa(username: username, privateKey: key)
        default:
            throw RemodexNativeSSHTerminalError.unsupportedPrivateKey(keyType.description)
        }
    }
}

private struct RemodexSSHKnownHostValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let host: String
    let port: Int

    nonisolated init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    nonisolated func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let currentHostKey = String(openSSHPublicKey: hostKey)
        if let storedHostKey = RemodexSSHKnownHostStore.load(host: host, port: port) {
            if storedHostKey == currentHostKey {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(RemodexNativeSSHTerminalError.hostKeyChanged)
            }
            return
        }

        RemodexSSHKnownHostStore.save(currentHostKey, host: host, port: port)
        validationCompletePromise.succeed(())
    }
}
