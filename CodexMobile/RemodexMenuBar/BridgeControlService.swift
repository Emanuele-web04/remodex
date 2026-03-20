// FILE: BridgeControlService.swift
// Purpose: Wraps the existing remodex/npm shell commands so the menu bar app can detect the global CLI and control the bridge.
// Layer: Companion app service
// Exports: BridgeControlService, ShellCommandRunner
// Depends on: Foundation, BridgeControlModels

import Foundation

struct ShellCommandResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum BridgeControlError: LocalizedError {
    case commandFailed(command: String, message: String)
    case invalidSnapshot(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(_, let message):
            return message
        case .invalidSnapshot(let message):
            return message
        }
    }
}

final class ShellCommandRunner {
    // Runs a login shell so Homebrew, nvm, asdf, and other user PATH customizations resolve naturally.
    func run(command: String, environment: [String: String] = [:]) async throws -> ShellCommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdoutReader = Task.detached(priority: .userInitiated) {
                stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let stderrReader = Task.detached(priority: .userInitiated) {
                stderrPipe.fileHandleForReading.readDataToEndOfFile()
            }

            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in
                override
            }
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()
            process.waitUntilExit()

            let stdout = String(data: await stdoutReader.value, encoding: .utf8) ?? ""
            let stderr = String(data: await stderrReader.value, encoding: .utf8) ?? ""
            let result = ShellCommandResult(
                stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                exitCode: process.terminationStatus
            )

            guard result.exitCode == 0 else {
                let message = result.stderr.isEmpty ? result.stdout : result.stderr
                throw BridgeControlError.commandFailed(
                    command: command,
                    message: message.isEmpty ? "Command failed: \(command)" : message
                )
            }

            return result
        }.value
    }
}

final class BridgeControlService {
    private let runner: ShellCommandRunner
    private let decoder = JSONDecoder()

    init(runner: ShellCommandRunner = ShellCommandRunner()) {
        self.runner = runner
    }

    // Confirms the product contract for this companion: a global `remodex` CLI must be runnable first.
    func detectCLIAvailability() async -> BridgeCLIAvailability {
        do {
            let result = try await runner.run(command: "remodex --version")
            guard let version = parseLatestVersion(result.stdout) else {
                return .broken(message: "The installed CLI returned an unreadable version.")
            }

            return .available(version: version)
        } catch {
            return classifyCLIAvailability(from: error)
        }
    }

    // Loads the daemon snapshot from the CLI so the menu bar stays aligned with the package's real control plane.
    func loadSnapshot(relayOverride: String?) async throws -> BridgeSnapshot {
        let result = try await runner.run(
            command: "remodex status --json",
            environment: commandEnvironment(relayOverride: relayOverride)
        )
        guard let data = result.stdout.data(using: .utf8) else {
            throw BridgeControlError.invalidSnapshot("Bridge status returned invalid UTF-8.")
        }

        do {
            return try decoder.decode(BridgeSnapshot.self, from: data)
        } catch {
            throw BridgeControlError.invalidSnapshot("Bridge status returned malformed JSON.")
        }
    }

    func startBridge(relayOverride: String?) async throws {
        _ = try await runner.run(
            command: "remodex start",
            environment: commandEnvironment(relayOverride: relayOverride)
        )
    }

    func stopBridge(relayOverride: String?) async throws {
        _ = try await runner.run(
            command: "remodex stop",
            environment: commandEnvironment(relayOverride: relayOverride)
        )
    }

    func resumeLastThread(relayOverride: String?) async throws {
        _ = try await runner.run(
            command: "remodex resume",
            environment: commandEnvironment(relayOverride: relayOverride)
        )
    }

    func resetPairing(relayOverride: String?) async throws {
        _ = try await runner.run(
            command: "remodex reset-pairing",
            environment: commandEnvironment(relayOverride: relayOverride)
        )
    }

    func updateBridgePackage() async throws {
        _ = try await runner.run(command: "npm install -g remodex@latest")
    }

    func fetchLatestPackageVersion() async -> Result<String, Error> {
        do {
            let result = try await runner.run(command: "npm view remodex version --json")
            let latestVersion = parseLatestVersion(result.stdout)
            guard let latestVersion else {
                throw BridgeControlError.commandFailed(
                    command: "npm view remodex version --json",
                    message: "npm returned an unreadable version."
                )
            }
            return .success(latestVersion)
        } catch {
            return .failure(error)
        }
    }

    private func parseLatestVersion(_ output: String) -> String? {
        guard !output.isEmpty else {
            return nil
        }

        if let data = output.data(using: .utf8),
           let stringValue = try? decoder.decode(String.self, from: data),
           !stringValue.isEmpty {
            return stringValue
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // Maps shell failures into the explicit "missing global CLI" state shown by the menu bar.
    private func classifyCLIAvailability(from error: Error) -> BridgeCLIAvailability {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = message.lowercased()

        if normalized.contains("command not found: remodex")
            || normalized.contains("remodex: command not found")
            || normalized.contains("remodex: not found")
            || normalized.contains("no such file or directory") {
            return .missing
        }

        return .broken(message: message.isEmpty ? "The CLI returned an unknown error." : message)
    }

    private func commandEnvironment(relayOverride: String?) -> [String: String] {
        guard let relayOverride,
              !relayOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [:]
        }

        return [
            "REMODEX_RELAY": relayOverride.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
    }
}
