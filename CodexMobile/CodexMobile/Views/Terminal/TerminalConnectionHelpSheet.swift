// FILE: TerminalConnectionHelpSheet.swift
// Purpose: User-friendly setup guide for creating an SSH connection from Remodex.
// Layer: View Component
// Exports: TerminalConnectionHelpSheet
// Depends on: SwiftUI, UIKit, RemodexIcon, HapticFeedback

import SwiftUI
import UIKit

private enum TerminalConnectionHelpPlatform: String, CaseIterable, Identifiable {
    case mac = "Mac"
    case windows = "Windows"

    var id: String { rawValue }

    var masterPrompt: String {
        switch self {
        case .mac:
            return """
            I'm setting up Remodex on my iPhone so I can open a terminal on my Mac over SSH.

            Please walk me through the whole setup, one step at a time:
            1. Help me find my Mac's local address and username.
            2. Turn on Remote Login (SSH) on this Mac.
            3. Create a dedicated SSH key pair for Remodex and add the public key to this Mac.
            4. Tell me exactly what to enter in Remodex: connection string (user@host), nickname, private key, and port.

            Keep it beginner-friendly. Tell me exactly what to click or type, and ask me one question at a time if you need more info.
            """
        case .windows:
            return """
            I'm setting up Remodex on my iPhone so I can open a terminal on my Windows PC over SSH.

            Please walk me through the whole setup, one step at a time:
            1. Help me find my Windows PC's local IP address and username.
            2. Install and enable the OpenSSH Server on this Windows machine.
            3. Create a dedicated SSH key pair for Remodex and add the public key to this PC.
            4. Tell me exactly what to enter in Remodex: connection string (user@host), nickname, private key, and port.

            Keep it beginner-friendly. Tell me exactly what to click or type, and ask me one question at a time if you need more info.
            """
        }
    }
}

private struct TerminalConnectionHelpStep: Identifiable {
    let number: Int
    let title: String
    let icon: String
    let body: String
    var command: String? = nil

    var id: String { "\(number)-\(title)" }
}

struct TerminalConnectionHelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var platform: TerminalConnectionHelpPlatform = .mac

    private var steps: [TerminalConnectionHelpStep] {
        TerminalConnectionHelpStep.steps(for: platform)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("SSH is the secure tunnel Remodex uses to reach your Mac or PC. You need an address, a username, SSH enabled, and a private key.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Picker("Platform", selection: $platform) {
                        ForEach(TerminalConnectionHelpPlatform.allCases) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)

                    if platform == .windows {
                        TerminalWindowsConnectionGuide(steps: steps)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                                TerminalConnectionHelpStepRow(
                                    step: step,
                                    isLast: index == steps.count - 1
                                )
                            }
                        }
                    }

                    TerminalConnectionHelpPromptRow(
                        prompt: platform.masterPrompt
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .animation(.easeInOut(duration: 0.2), value: platform)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("SSH Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct TerminalWindowsConnectionGuide: View {
    let steps: [TerminalConnectionHelpStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect to Windows with SSH")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.primary)

                Text("Run these in an Administrator PowerShell on the Windows PC, then create a terminal profile in Remodex.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(steps) { step in
                    TerminalWindowsConnectionStep(step: step)
                }
            }

            Text("Recommended private-key format: OpenSSH Ed25519 with a passphrase, created by ssh-keygen above. Remodex also accepts encrypted PKCS#8 and encrypted legacy PEM keys; unencrypted keys work only if you explicitly enable that option on the profile. In Remodex, use the Windows username, PC IPv4 address, port 22, and the matching private key. Administrator accounts use C:\\ProgramData\\ssh\\administrators_authorized_keys instead.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color(.separator).opacity(0.45), lineWidth: 0.75)
                )
        }
    }
}

private struct TerminalWindowsConnectionStep: View {
    let step: TerminalConnectionHelpStep

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(step.number). \(step.title)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let command = step.command {
                TerminalConnectionCommandBlock(command: command)
            }

            if !step.body.isEmpty {
                Text(step.body)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct TerminalConnectionCommandBlock: View {
    let command: String
    @State private var didCopy = false

    var body: some View {
        Button {
            UIPasteboard.general.string = command
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            withAnimation(.easeInOut(duration: 0.15)) { didCopy = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeInOut(duration: 0.15)) { didCopy = false }
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(command)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                RemodexIcon.image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(didCopy ? .primary : .tertiary)
                    .frame(width: 18, height: 18)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(.separator).opacity(0.45), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(didCopy ? "Command copied" : "Copy command")
    }
}

private struct TerminalConnectionHelpPromptRow: View {
    let prompt: String
    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Need help?")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Copy a ready-made prompt and paste it into any AI.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button {
                UIPasteboard.general.string = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                withAnimation(.easeInOut(duration: 0.15)) { didCopy = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeInOut(duration: 0.15)) { didCopy = false }
                }
            } label: {
                Group {
                    if didCopy {
                        RemodexIcon.image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                    } else {
                        Image("copy")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                    }
                }
                .frame(width: 16, height: 16)
                .foregroundStyle(didCopy ? .primary : .secondary)
                .frame(width: 36, height: 36)
                .background(Color(.tertiarySystemBackground), in: Circle())
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(didCopy ? "Prompt copied" : "Copy setup prompt")
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct TerminalConnectionHelpStepRow: View {
    let step: TerminalConnectionHelpStep
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.1))
                        .frame(width: 26, height: 26)

                    Text("\(step.number)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                }

                if !isLast {
                    Rectangle()
                        .fill(Color(.separator).opacity(0.4))
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 3)
                }
            }
            .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    RemodexIcon.image(systemName: step.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text(step.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                Text(step.body)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, isLast ? 0 : 16)
        }
    }
}

private extension TerminalConnectionHelpStep {
    static func steps(for platform: TerminalConnectionHelpPlatform) -> [TerminalConnectionHelpStep] {
        switch platform {
        case .mac:
            return [
                TerminalConnectionHelpStep(
                    number: 1,
                    title: "Choose the Mac",
                    icon: "laptopcomputer",
                    body: "Use the Mac where you want commands to run. It needs to be awake and reachable from your iPhone, usually on the same Wi‑Fi or through your VPN."
                ),
                TerminalConnectionHelpStep(
                    number: 2,
                    title: "Turn on Remote Login",
                    icon: "lock.shield",
                    body: "Open System Settings → General → Sharing and turn on Remote Login. This enables SSH so trusted devices can open a terminal session."
                ),
                TerminalConnectionHelpStep(
                    number: 3,
                    title: "Create a Remodex key",
                    icon: "key",
                    body: "Open Terminal and create a dedicated SSH key for Remodex. The public half is allowed on the Mac; the private half is pasted into Remodex and should not be shared anywhere else."
                ),
                TerminalConnectionHelpStep(
                    number: 4,
                    title: "Fill in the connection",
                    icon: "terminal",
                    body: "In Remodex, enter the connection as user@address, give it a nickname, paste the private key, and leave the port as 22 unless you changed it."
                ),
                TerminalConnectionHelpStep(
                    number: 5,
                    title: "Connect and trust once",
                    icon: "checkmark.seal.fill",
                    body: "The first connection may ask you to trust the host key. Accept only when the computer is the one you intended. If you change machines later, reset the saved host key in the connection editor."
                )
            ]
        case .windows:
            return [
                TerminalConnectionHelpStep(
                    number: 1,
                    title: "Install OpenSSH Server",
                    icon: "desktopcomputer",
                    body: "",
                    command: "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0"
                ),
                TerminalConnectionHelpStep(
                    number: 2,
                    title: "Start SSH and enable it on boot",
                    icon: "lock.shield",
                    body: "",
                    command: """
                    Start-Service sshd
                    Set-Service -Name sshd -StartupType Automatic
                    """
                ),
                TerminalConnectionHelpStep(
                    number: 3,
                    title: "Create a key on the device that will connect",
                    icon: "key",
                    body: "When asked, choose a passphrase for the recommended secure setup.",
                    command: "ssh-keygen -t ed25519 -f $HOME\\.ssh\\remodex_ed25519"
                ),
                TerminalConnectionHelpStep(
                    number: 4,
                    title: "Add that public key for the Windows user you will log in as",
                    icon: "terminal",
                    body: "Paste the contents of remodex_ed25519.pub into authorized_keys.",
                    command: """
                    mkdir $HOME\\.ssh -Force
                    notepad $HOME\\.ssh\\authorized_keys
                    """
                ),
                TerminalConnectionHelpStep(
                    number: 5,
                    title: "Find the PC IP, then use it in Remodex",
                    icon: "checkmark.seal.fill",
                    body: "",
                    command: "ipconfig"
                )
            ]
        }
    }
}
