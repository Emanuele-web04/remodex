// FILE: RemodexNativeSSHTerminal.swift
// Purpose: Owns the phone-side SSH client and bridges raw TTY bytes to Ghostty.
// Layer: Service
// Exports: RemodexNativeSSHTerminal, RemodexNativeSSHTerminalError
// Depends on: Citadel, Crypto, Darwin, Foundation, NIOCore, NIOPosix

import Citadel
import Crypto
import Darwin
import Foundation
import NIO
import NIOCore
import NIOPosix
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

    // Converts low-level SSH/NIO failures into copy that tells the user what to check next.
    static func userFacingDescription(for error: Error) -> String {
        if let terminalError = error as? RemodexNativeSSHTerminalError,
           let description = terminalError.errorDescription {
            return description
        }
        if let sshError = error as? SSHClientError {
            return userFacingDescription(for: sshError)
        }
        if let channelError = error as? ChannelError {
            return userFacingDescription(for: channelError)
        }
        if let connectionError = error as? NIOConnectionError {
            return userFacingDescription(for: connectionError)
        }
        if let ioError = error as? IOError {
            return userFacingDescription(for: ioError)
        }
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }

        let fallback = error.localizedDescription
        if fallback.contains("NIOCore.ChannelError") {
            return "SSH connection closed before the terminal was ready. Check that Remote Login is enabled on the Mac, the saved host/IP is still current, and the Mac is reachable from this network."
        }
        if fallback.contains("NIOPosix.NIOConnectionError") {
            return "SSH could not reach the Mac. Check that Remote Login is enabled, the saved host/IP and port are correct, and both devices are on a network that allows local SSH."
        }
        return fallback
    }

    private static func userFacingDescription(for error: SSHClientError) -> String {
        switch error {
        case .allAuthenticationOptionsFailed:
            return "SSH authentication failed. Check the username, private key, passphrase, and that the public key is still in ~/.ssh/authorized_keys on the Mac."
        case .unsupportedPrivateKeyAuthentication:
            return "This SSH server is not accepting private-key authentication for that user."
        case .unsupportedPasswordAuthentication:
            return "This SSH server is asking for password authentication, but Remodex terminal currently uses a private key."
        case .unsupportedHostBasedAuthentication:
            return "This SSH server requires host-based authentication, which Remodex terminal does not support."
        case .channelCreationFailed:
            return "SSH connected, but the terminal channel could not be opened. Check whether the Mac allows interactive login for this user."
        }
    }

    private static func userFacingDescription(for error: ChannelError) -> String {
        switch error {
        case .connectTimeout(_):
            return "SSH connection timed out. Check that the Mac is awake, Remote Login is enabled, and the saved host/IP and port are reachable from this network."
        case .eof, .inputClosed, .outputClosed, .ioOnClosedChannel, .alreadyClosed:
            return "SSH connection closed before the terminal was ready. Check that Remote Login is enabled on the Mac and retry. If this Mac was restored or reinstalled, reset the terminal host key first."
        case .connectPending:
            return "SSH is already connecting. Wait a moment and try again."
        default:
            return "SSH channel failed before the terminal was ready. Check the saved host/IP, port, Remote Login setting, and network reachability."
        }
    }

    private static func userFacingDescription(for error: NIOConnectionError) -> String {
        if error.dnsAError != nil || error.dnsAAAAError != nil {
            return "SSH could not resolve \(error.host). Check the saved hostname or use the Mac's current local IP address."
        }

        if let failedConnection = error.connectionErrors.first {
            if let ioError = failedConnection.error as? IOError {
                return userFacingDescription(for: ioError)
            }
            if let channelError = failedConnection.error as? ChannelError {
                return userFacingDescription(for: channelError)
            }
        }

        return "SSH could not reach \(error.host):\(error.port). Check that the Mac is awake, Remote Login is enabled, the saved host/IP is current, and the network allows local SSH."
    }

    private static func userFacingDescription(for error: IOError) -> String {
        switch error.errnoCode {
        case ECONNREFUSED:
            return "The Mac refused the SSH connection. Enable Remote Login on the Mac and confirm the terminal port is correct."
        case EHOSTUNREACH, ENETUNREACH:
            return "The Mac is not reachable from this network. Check that the iPhone and Mac are on the same network and that the saved host/IP is still current."
        case ETIMEDOUT:
            return "SSH connection timed out. Check that the Mac is awake, Remote Login is enabled, and the saved host/IP is still current."
        case ECONNRESET, ECONNABORTED, EPIPE:
            return "SSH connection was closed by the Mac or the network. Reopen the terminal after checking Remote Login and network reachability."
        default:
            return "SSH network error: \(error.localizedDescription)"
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
