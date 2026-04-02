// FILE: BridgeControlService.swift
// Purpose: Wraps the existing remodex/npm shell commands so the menu bar app can detect the global CLI and control the bridge.
// Layer: Companion app service
// Exports: BridgeControlService, ShellCommandRunner
// Depends on: Foundation, BridgeControlModels

import Foundation

struct BridgeCLIInvocation {
    let nodePath: String
    let remodexPath: String

    // Executes the actual CLI entrypoint via an absolute Node binary so GUI PATH drift does not break nvm installs.
    func command(_ arguments: [String]) -> String {
        ([shellQuoted(nodePath), shellQuoted(remodexPath)] + arguments).joined(separator: " ")
    }
}

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
            process.arguments = ["-lc", self.wrappedShellCommand(command)]
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

    // Silently loads interactive zsh PATH customizations so GUI-launched commands see the same global CLI install as Terminal.
    private func wrappedShellCommand(_ command: String) -> String {
        [
            "export TERM=dumb",
            "source ~/.zshrc >/dev/null 2>/dev/null || true",
            command,
        ].joined(separator: "; ")
    }
}

final class BridgeControlService {
    private let runner: ShellCommandRunner
    private let decoder = JSONDecoder()
    private let fileManager = FileManager.default
    private let defaultStateDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".remodex", isDirectory: true)
    private let launchAgentPlistURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("LaunchAgents", isDirectory: true)
        .appendingPathComponent("com.remodex.bridge.plist")

    init(runner: ShellCommandRunner = ShellCommandRunner()) {
        self.runner = runner
    }

    // Confirms the product contract for this companion: a global `remodex` CLI must be runnable first.
    func detectCLIAvailability() async -> BridgeCLIAvailability {
        do {
            let invocation = try await resolveCLIInvocation()
            let result = try await runner.run(command: invocation.command(["--version"]))
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
        let invocation = try await resolveCLIInvocation()
        let result = try await runner.run(
            command: invocation.command(["status", "--json"]),
            environment: commandEnvironment(relayOverride: relayOverride)
        )
        guard let data = result.stdout.data(using: .utf8) else {
            throw BridgeControlError.invalidSnapshot("Bridge status returned invalid UTF-8.")
        }

        do {
            return try decoder.decode(BridgeSnapshot.self, from: data)
        } catch {
            return try await loadFallbackSnapshot(from: result.stdout, invocation: invocation)
        }
    }

    func startBridge(relayOverride: String?) async throws {
        let invocation = try await resolveCLIInvocation()
        _ = try await runner.run(
            command: invocation.command(["start"]),
            environment: commandEnvironment(relayOverride: relayOverride)
        )
    }

    func stopBridge(relayOverride: String?) async throws {
        let invocation = try await resolveCLIInvocation()
        _ = try await runner.run(
            command: invocation.command(["stop"]),
            environment: commandEnvironment(relayOverride: relayOverride)
        )
    }

    func resumeLastThread(relayOverride: String?) async throws {
        let invocation = try await resolveCLIInvocation()
        _ = try await runner.run(
            command: invocation.command(["resume"]),
            environment: commandEnvironment(relayOverride: relayOverride)
        )
    }

    func resetPairing(relayOverride: String?) async throws {
        let invocation = try await resolveCLIInvocation()
        _ = try await runner.run(
            command: invocation.command(["reset-pairing"]),
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

    // Falls back to the daemon-state files when the global CLI still prints human-readable status output.
    private func loadFallbackSnapshot(
        from statusOutput: String,
        invocation: BridgeCLIInvocation
    ) async throws -> BridgeSnapshot {
        let statusLines = parseStatusLines(statusOutput)
        guard !statusLines.isEmpty else {
            throw BridgeControlError.invalidSnapshot("Bridge status returned malformed JSON.")
        }

        let versionResult = try await runner.run(command: invocation.command(["--version"]))
        guard let currentVersion = parseLatestVersion(versionResult.stdout) else {
            throw BridgeControlError.invalidSnapshot("Bridge status returned an unreadable CLI version.")
        }

        let stateDirectory = resolveStateDirectory(statusLines: statusLines)
        let daemonConfig: BridgeDaemonConfig? = readStateFile(named: "daemon-config.json", in: stateDirectory)
        let bridgeStatus: BridgeRuntimeStatus? = readStateFile(named: "bridge-status.json", in: stateDirectory)
        let pairingSession: BridgePairingSession? = readStateFile(named: "pairing-session.json", in: stateDirectory)
        let stdoutLogPath = statusLines["stdout log"] ?? stateDirectory.appendingPathComponent("logs/bridge.stdout.log").path
        let stderrLogPath = statusLines["stderr log"] ?? stateDirectory.appendingPathComponent("logs/bridge.stderr.log").path
        let launchdPid = parsePid(statusLines["pid"])
        let launchdLoaded = parseYesNo(statusLines["launchd loaded"]) ?? false
        let installed = parseYesNo(statusLines["installed"]) ?? fileManager.fileExists(atPath: launchAgentPlistURL.path)

        return BridgeSnapshot(
            currentVersion: currentVersion,
            label: statusLines["service label"] ?? "com.remodex.bridge",
            platform: "darwin",
            installed: installed,
            launchdLoaded: launchdLoaded,
            launchdPid: launchdPid,
            daemonConfig: daemonConfig,
            bridgeStatus: bridgeStatus,
            pairingSession: pairingSession,
            stdoutLogPath: stdoutLogPath,
            stderrLogPath: stderrLogPath
        )
    }

    // Resolves both the CLI script and the Node runtime from stable absolute paths before the menu bar invokes them.
    private func resolveCLIInvocation() async throws -> BridgeCLIInvocation {
        let remodexPath = try await resolveExecutable(named: "remodex")
        let nodePath = try await resolveNodePath(for: remodexPath)
        return BridgeCLIInvocation(nodePath: nodePath, remodexPath: remodexPath)
    }

    private func parseStatusLines(_ output: String) -> [String: String] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .reduce(into: [String: String]()) { partialResult, line in
                let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = "[remodex] "
                guard cleaned.hasPrefix(prefix) else {
                    return
                }

                let payload = cleaned.dropFirst(prefix.count)
                guard let separatorIndex = payload.firstIndex(of: ":") else {
                    return
                }

                let key = payload[..<separatorIndex]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let value = payload[payload.index(after: separatorIndex)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                partialResult[key] = value
            }
    }

    private func parseYesNo(_ value: String?) -> Bool? {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes":
            return true
        case "no":
            return false
        default:
            return nil
        }
    }

    private func parsePid(_ value: String?) -> Int? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int(value) else {
            return nil
        }

        return pid
    }

    // Reads daemon-state files from the same state root used by the bridge service.
    private func readStateFile<T: Decodable>(named filename: String, in stateDirectory: URL) -> T? {
        let targetURL = stateDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: targetURL) else {
            return nil
        }

        return try? decoder.decode(T.self, from: data)
    }

    // Prefers the Node runtime sitting next to the resolved CLI binary so mixed installs stay compatible.
    private func resolveNodePath(for remodexPath: String) async throws -> String {
        if let colocatedNodePath = resolveColocatedNodePath(for: remodexPath) {
            return colocatedNodePath
        }

        return try await resolveExecutable(named: "node")
    }

    private func resolveColocatedNodePath(for remodexPath: String) -> String? {
        let remodexURL = URL(fileURLWithPath: remodexPath)
        let candidateDirectories = [
            remodexURL.deletingLastPathComponent().path,
            remodexURL.resolvingSymlinksInPath().deletingLastPathComponent().path,
        ]

        var seenDirectories = Set<String>()
        for directory in candidateDirectories where seenDirectories.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("node")
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private func resolveExecutable(named name: String) async throws -> String {
        if let discovered = try? await runner.run(command: "command -v \(name)"),
           let path = parseExecutablePath(discovered.stdout),
           fileManager.isExecutableFile(atPath: path) {
            return path
        }

        if let fallback = fallbackExecutableCandidates(named: name).first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return fallback
        }

        throw BridgeControlError.commandFailed(
            command: name,
            message: "\(name) was not found in the app shell environment."
        )
    }

    private func parseExecutablePath(_ output: String) -> String? {
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private func fallbackExecutableCandidates(named name: String) -> [String] {
        let homeDirectory = NSHomeDirectory()
        let stableCandidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(homeDirectory)/.local/bin/\(name)",
            "\(homeDirectory)/.volta/bin/\(name)",
        ]

        return stableCandidates + nvmExecutableCandidates(named: name, homeDirectory: homeDirectory)
    }

    private func nvmExecutableCandidates(named name: String, homeDirectory: String) -> [String] {
        let versionsDirectory = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".nvm", isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent("node", isDirectory: true)

        guard let contents = try? fileManager.contentsOfDirectory(
            at: versionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .sorted { compareVersionDirectoryNames($0.lastPathComponent, $1.lastPathComponent) == .orderedDescending }
            .map { $0.appendingPathComponent("bin", isDirectory: true).appendingPathComponent(name).path }
    }

    // Mirrors the bridge daemon-state lookup order so old CLI output still hydrates the companion correctly.
    private func resolveStateDirectory(statusLines: [String: String]) -> URL {
        if let explicitStateDirectory = normalizeNonEmptyString(ProcessInfo.processInfo.environment["REMODEX_DEVICE_STATE_DIR"]) {
            return URL(fileURLWithPath: explicitStateDirectory, isDirectory: true)
        }

        if let installedStateDirectory = readLaunchAgentStateDirectory() {
            return installedStateDirectory
        }

        if let derivedStateDirectory = deriveStateDirectory(fromLogPath: statusLines["stdout log"] ?? statusLines["stderr log"]) {
            return derivedStateDirectory
        }

        return defaultStateDirectory
    }

    private func readLaunchAgentStateDirectory() -> URL? {
        guard let data = try? Data(contentsOf: launchAgentPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let environment = plist["EnvironmentVariables"] as? [String: Any],
              let stateDirectory = normalizeNonEmptyString(environment["REMODEX_DEVICE_STATE_DIR"] as? String) else {
            return nil
        }

        return URL(fileURLWithPath: stateDirectory, isDirectory: true)
    }

    private func deriveStateDirectory(fromLogPath logPath: String?) -> URL? {
        guard let logPath = normalizeNonEmptyString(logPath) else {
            return nil
        }

        return URL(fileURLWithPath: logPath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func compareVersionDirectoryNames(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsVersion = parseVersionDirectoryName(lhs)
        let rhsVersion = parseVersionDirectoryName(rhs)

        switch (lhsVersion, rhsVersion) {
        case let (.some(lhsVersion), .some(rhsVersion)):
            return compareVersionComponents(lhsVersion, rhsVersion)
        case (.some, .none):
            return .orderedDescending
        case (.none, .some):
            return .orderedAscending
        case (.none, .none):
            return lhs.localizedStandardCompare(rhs)
        }
    }

    private func parseVersionDirectoryName(_ value: String) -> [Int]? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "v", with: "", options: [.anchored])
        let coreVersion = normalized.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true).first
        guard let coreVersion else {
            return nil
        }

        let parts = coreVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else {
            return nil
        }

        let numericParts = parts.compactMap { Int($0) }
        guard numericParts.count == parts.count else {
            return nil
        }

        return numericParts
    }

    private func compareVersionComponents(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        for index in 0..<max(lhs.count, rhs.count) {
            let lhsValue = index < lhs.count ? lhs[index] : 0
            let rhsValue = index < rhs.count ? rhs[index] : 0

            if lhsValue == rhsValue {
                continue
            }

            return lhsValue < rhsValue ? .orderedAscending : .orderedDescending
        }

        return .orderedSame
    }

    private func normalizeNonEmptyString(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
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

private func shellQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}
