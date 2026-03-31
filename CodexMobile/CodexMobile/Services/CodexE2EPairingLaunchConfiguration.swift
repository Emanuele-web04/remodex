// FILE: CodexE2EPairingLaunchConfiguration.swift
// Purpose: Simulator-only test launch contract for injecting relay pairing JSON without camera QR scanning.
// Layer: Services
// Exports: CodexE2EPairingLaunchConfiguration

import Foundation
import SwiftUI

/// Simulator-only launch-time pairing injection for testing: `-CodexE2EPairingBypass` plus
/// `CODEX_E2E_PAIRING_JSON` or `CODEX_E2E_PAIRING_FILE` (ignored on physical devices).
///
/// **Simulator DEBUG:** set `CodexSimulatorPairingCodeInjection.isEnabled` to load
/// `pairing-session.json` from disk without scheme env/args (see `pairingSessionFileURL`).
/// Launch args and env still take precedence when present.
struct CodexE2EPairingLaunchConfiguration: Sendable {
    /// True when `-CodexE2EPairingBypass` is present for a test/dev launch.
    let isPairingBypassActive: Bool
    /// Raw JSON matching `CodexPairingQRPayload` when env/file provided; may be nil if the flag is set but payload missing.
    let resolvedPairingJSON: String?

    static let disabled = CodexE2EPairingLaunchConfiguration(
        isPairingBypassActive: false,
        resolvedPairingJSON: nil
    )

    /// Resolved from `ProcessInfo` at launch; bypass activates only on the simulator.
    static var current: CodexE2EPairingLaunchConfiguration {
        resolve(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        )
    }

    static func resolve(arguments: [String], environment: [String: String]) -> CodexE2EPairingLaunchConfiguration {
        // QR-less injection is Simulator-only; device builds ignore flags and env (see unit tests).
#if !targetEnvironment(simulator)
        return .disabled
#endif

#if DEBUG
        let codeInjection = CodexSimulatorPairingCodeInjection.isEnabled
#else
        let codeInjection = false
#endif

        let launchBypass = arguments.contains(Self.launchArgumentFlag)
        guard launchBypass || codeInjection else {
            return .disabled
        }

        if let json = environment[Self.pairingJSONEnvironmentKey] {
            let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return CodexE2EPairingLaunchConfiguration(
                    isPairingBypassActive: true,
                    resolvedPairingJSON: json
                )
            }
        }

        if let path = environment[Self.pairingFileEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty,
           let contents = try? String(contentsOfFile: path, encoding: .utf8) {
            return CodexE2EPairingLaunchConfiguration(
                isPairingBypassActive: true,
                resolvedPairingJSON: contents
            )
        }

#if DEBUG
#if targetEnvironment(simulator)
        if codeInjection,
           let contents = try? String(contentsOf: CodexSimulatorPairingCodeInjection.pairingSessionFileURL, encoding: .utf8),
           !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return CodexE2EPairingLaunchConfiguration(
                isPairingBypassActive: true,
                resolvedPairingJSON: contents
            )
        }
#endif
#endif

        return CodexE2EPairingLaunchConfiguration(
            isPairingBypassActive: true,
            resolvedPairingJSON: nil
        )
    }

#if DEBUG
#if targetEnvironment(simulator)
    /// When simulator code injection is on and `alsoSkipOnboarding` is true, matches `-CodexSkipOnboarding` for onboarding gating.
    static var simulatorSkipsOnboardingForCodeInjection: Bool {
        guard CodexSimulatorPairingCodeInjection.isEnabled else {
            return false
        }
        return CodexSimulatorPairingCodeInjection.alsoSkipOnboarding
    }
#endif
#endif

    /// Unit-test hook: bypasses runtime/launch-arg checks.
    static func testing(pairingBypassActive: Bool, pairingJSON: String?) -> CodexE2EPairingLaunchConfiguration {
        CodexE2EPairingLaunchConfiguration(
            isPairingBypassActive: pairingBypassActive,
            resolvedPairingJSON: pairingJSON
        )
    }

    private static let launchArgumentFlag = "-CodexE2EPairingBypass"
    private static let pairingJSONEnvironmentKey = "CODEX_E2E_PAIRING_JSON"
    private static let pairingFileEnvironmentKey = "CODEX_E2E_PAIRING_FILE"
}

#if DEBUG
#if targetEnvironment(simulator)
/// Flip **`isEnabled`** to inject pairing from disk in Simulator without Xcode scheme env/args.
private enum CodexSimulatorPairingCodeInjection {
    /// Load `pairingSessionFileURL` when bypass is active and env did not supply JSON.
    /// Set to `true` in your tree for Simulator dev (no scheme flags needed).
    static let isEnabled = false
    /// When `isEnabled`, mark onboarding complete (same effect as `-CodexSkipOnboarding`).
    static let alsoSkipOnboarding = true

    /// Same layout as the bridge: `REMODEX_DEVICE_STATE_DIR/pairing-session.json` or `~/.remodex/pairing-session.json`.
    static var pairingSessionFileURL: URL {
        if let dir = ProcessInfo.processInfo.environment["REMODEX_DEVICE_STATE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("pairing-session.json")
        }
        // `FileManager.homeDirectoryForCurrentUser` is unavailable on iOS; prefer `HOME` (often the Mac user
        // home when running Simulator from Xcode) so default path matches `~/.remodex/pairing-session.json`.
        let home: URL
        if let homeEnv = ProcessInfo.processInfo.environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !homeEnv.isEmpty {
            home = URL(fileURLWithPath: homeEnv, isDirectory: true)
        } else {
            home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        }
        return home
            .appendingPathComponent(".remodex")
            .appendingPathComponent("pairing-session.json")
    }
}
#endif
#endif

private struct CodexE2EPairingLaunchConfigurationKey: EnvironmentKey {
    static let defaultValue = CodexE2EPairingLaunchConfiguration.disabled
}

extension EnvironmentValues {
    var codexE2EPairingLaunchConfiguration: CodexE2EPairingLaunchConfiguration {
        get { self[CodexE2EPairingLaunchConfigurationKey.self] }
        set { self[CodexE2EPairingLaunchConfigurationKey.self] = newValue }
    }
}
