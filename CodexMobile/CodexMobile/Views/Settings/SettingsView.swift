// FILE: SettingsView.swift
// Purpose: Settings for Local Mode (Codex runs on the paired computer, relay WebSocket).
// Layer: View
// Exports: SettingsView

import SwiftUI
import UIKit

private struct SettingsComputerNamePresentation: Identifiable {
    let deviceId: String?
    let currentName: String
    let systemName: String

    var id: String { deviceId ?? currentName }
}

struct SettingsView: View {
    @Environment(CodexService.self) private var codex
    @AppStorage("codex.appFontStyle") private var appFontStyleRawValue = AppFont.defaultStoredStyleRawValue
    @State private var computerNamePresentation: SettingsComputerNamePresentation?

    var body: some View {
        List {
            SettingsArchivedChatsCard()
            SettingsAppearanceCard(appFontStyle: appFontStyleBinding)
            SettingsAppIconCard()
            SettingsNotificationsCard()
            SettingsGPTAccountCard()
            SettingsSubscriptionCard()
            SettingsBridgeVersionCard()
            SettingsCommandReferenceCard()
            SettingsRuntimeDefaultsCard()
            SettingsAboutCard()
            SettingsUsageCard()
            SettingsConnectionCard {
                presentComputerNameSheet()
            }
        }
        .listStyle(.insetGrouped)
        .font(AppFont.body())
        .tint(.primary)
        .navigationTitle("Settings")
        // Own settings modals from the stable screen root; List rows can be
        // rebuilt while connection status changes and should not own sheets.
        .sheet(item: $computerNamePresentation) { presentation in
            SettingsComputerNameSheet(
                nickname: sidebarComputerNicknameBinding(for: presentation.deviceId),
                currentName: presentation.currentName,
                systemName: presentation.systemName
            )
        }
    }

    private var appFontStyleBinding: Binding<AppFont.Style> {
        Binding(
            get: { AppFont.Style(rawValue: appFontStyleRawValue) ?? AppFont.defaultStyle },
            set: { appFontStyleRawValue = $0.rawValue }
        )
    }

    // Captures the visible device details before presenting so reconnect updates cannot dismiss the editor.
    private func presentComputerNameSheet() {
        guard let trustedPairPresentation = codex.trustedPairPresentation else {
            return
        }

        computerNamePresentation = SettingsComputerNamePresentation(
            deviceId: trustedPairPresentation.deviceId,
            currentName: trustedPairPresentation.name,
            systemName: trustedPairPresentation.systemName ?? trustedPairPresentation.name
        )
    }

    // Writes nicknames against the tapped trusted computer so switching pairs does not reuse the wrong alias.
    private func sidebarComputerNicknameBinding(for deviceId: String?) -> Binding<String> {
        Binding(
            get: { SidebarComputerNicknameStore.nickname(for: deviceId) },
            set: { SidebarComputerNicknameStore.setNickname($0, for: deviceId) }
        )
    }
}

private struct SettingsUsageCard: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.scenePhase) private var scenePhase

    @State private var isRefreshing = false

    var body: some View {
        SettingsCard(title: "Usage") {
            UsageStatusSummaryContent(
                contextWindowUsage: nil,
                showsContextWindowSection: false,
                rateLimitBuckets: codex.rateLimitBuckets,
                isLoadingRateLimits: codex.isLoadingRateLimits,
                rateLimitsErrorMessage: codex.rateLimitsErrorMessage,
                refreshControl: UsageStatusRefreshControl(
                    title: "Refresh",
                    isRefreshing: isRefreshing,
                    action: refreshStatus
                )
            )
        }
        .task {
            await refreshStatusIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await refreshStatusIfNeeded()
            }
        }
    }

    private func refreshStatus() {
        guard !isRefreshing else { return }
        HapticFeedback.shared.triggerImpactFeedback(style: .light)
        isRefreshing = true

        Task {
            await refreshStatusData()
            await MainActor.run {
                isRefreshing = false
            }
        }
    }

    private func refreshStatusIfNeeded() async {
        guard !isRefreshing else { return }
        guard codex.shouldAutoRefreshUsageStatus(threadId: nil) else { return }

        await MainActor.run {
            isRefreshing = true
        }
        await refreshStatusData()
        await MainActor.run {
            isRefreshing = false
        }
    }

    // Settings only needs the account-wide usage windows.
    private func refreshStatusData() async {
        await codex.refreshUsageStatus(threadId: nil)
    }
}

private struct SettingsAppearanceCard: View {
    @Binding var appFontStyle: AppFont.Style
    @AppStorage(GlassPreference.storageKey) private var useLiquidGlass = true
    @AppStorage(UserBubbleColor.storageKey) private var userBubbleColorRawValue = UserBubbleColor.defaultStoredRawValue
    private let settingsAccentColor = Color.primary

    var body: some View {
        SettingsCard(title: "Appearance") {
            Picker("Font", selection: $appFontStyle) {
                ForEach(AppFont.Style.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.menu)
            .tint(settingsAccentColor)

            HStack {
                Text("Message Bubble")
                Menu {
                    ForEach(UserBubbleColor.allCases) { color in
                        Button {
                            userBubbleColorRawValue = color.rawValue
                        } label: {
                            Label {
                                Text(color.title)
                            } icon: {
                                Image(uiImage: color.menuSwatchImage)
                                    .renderingMode(.original)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        Circle()
                            .fill(selectedUserBubbleColor.swatchColor)
                            .frame(width: 14, height: 14)
                    }
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .trailing)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Message Bubble color")
                .accessibilityValue(selectedUserBubbleColor.title)
                .tint(settingsAccentColor)
            }

            if GlassPreference.isSupported {
                Toggle("Liquid Glass", isOn: $useLiquidGlass)
                    .tint(settingsToggleTintColor)
            }

            SettingsPetCompanionSection(settingsAccentColor: settingsAccentColor)
        }
    }

    private var selectedUserBubbleColor: UserBubbleColor {
        UserBubbleColor(rawValue: userBubbleColorRawValue) ?? .default
    }
}

private struct SettingsAppIconCard: View {
    @State private var selectedAppIcon = AppIconChoice.current
    @State private var appIconErrorMessage: String?

    var body: some View {
        if UIApplication.shared.supportsAlternateIcons {
            SettingsCard(title: "App Icon") {
                ForEach(AppIconChoice.allCases) { icon in
                    Button {
                        updateAppIcon(to: icon)
                    } label: {
                        AppIconChoiceRow(
                            icon: icon,
                            isSelected: selectedAppIcon == icon
                        )
                    }
                    .buttonStyle(.plain)
                }

                if let appIconErrorMessage {
                    Text(appIconErrorMessage)
                        .font(AppFont.caption())
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // Applies the selected icon through UIKit; Xcode generates the
    // alternate declarations from the Alternate App Icon Sets build setting.
    private func updateAppIcon(to appIcon: AppIconChoice) {
        guard selectedAppIcon != appIcon else {
            return
        }

        appIconErrorMessage = nil
        HapticFeedback.shared.triggerImpactFeedback(style: .light)

        UIApplication.shared.setAlternateIconName(appIcon.alternateIconName) { error in
            Task { @MainActor in
                if let error {
                    appIconErrorMessage = error.localizedDescription
                    selectedAppIcon = AppIconChoice.current
                } else {
                    selectedAppIcon = appIcon
                }
            }
        }
    }
}

private struct AppIconChoiceRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let icon: AppIconChoice
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            iconPreview

            VStack(alignment: .leading, spacing: 3) {
                Text(icon.title)
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(.primary)

                Text(icon.subtitle)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if isSelected {
                RemodexIcon.image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.green)
            }
        }
        .frame(minHeight: 74)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var iconPreview: some View {
        switch icon {
        case .classic:
            AppIconPreviewImage(name: "AppIconClassicPreview", size: 52)
        case .contrast:
            AppIconPreviewImage(name: contrastPreviewName, size: 52)
        }
    }

    private var contrastPreviewName: String {
        colorScheme == .dark ? "AppIconContrastDarkPreview" : "AppIconContrastLightPreview"
    }
}

private struct AppIconPreviewImage: View {
    let name: String
    let size: CGFloat

    var body: some View {
        Image(name)
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
    }
}

private enum AppIconChoice: String, CaseIterable, Identifiable {
    case classic
    case contrast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic:
            "Classic"
        case .contrast:
            "Contrast"
        }
    }

    var subtitle: String {
        switch self {
        case .classic:
            "Remodex 2"
        case .contrast:
            "Dark in light mode, white in dark mode"
        }
    }

    var alternateIconName: String? {
        switch self {
        case .classic:
            nil
        case .contrast:
            "RemodexContrast"
        }
    }

    static var current: AppIconChoice {
        switch UIApplication.shared.alternateIconName {
        case AppIconChoice.contrast.alternateIconName:
            .contrast
        default:
            .classic
        }
    }
}

private struct SettingsPetCompanionSection: View {
    @Environment(CodexService.self) private var codex
    @Environment(PetCompanionStore.self) private var petStore

    let settingsAccentColor: Color

    var body: some View {
        Group {
            Toggle(isOn: petEnabledBinding) {
                HStack(spacing: 8) {
                    Text("Companion Pet")
                    Text("BETA")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(settingsAccentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(settingsAccentColor.opacity(0.15))
                        )
                }
            }
            .tint(settingsToggleTintColor)

            if petStore.isEnabled {
                if petStore.availablePets.isEmpty {
                    Text(petStore.isLoading
                         ? "Loading local Codex pets from your device..."
                         : "No local Codex pets found in ~/.codex/pets.")
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Pet", selection: selectedPetBinding) {
                        ForEach(petStore.availablePets) { pet in
                            Text(pet.displayName).tag(pet.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(settingsAccentColor)

                    if let description = petStore.selectedPet?.description,
                       !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(description)
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage = petStore.errorMessage {
                    Text(errorMessage)
                        .font(AppFont.caption())
                        .foregroundStyle(.red)
                }

                SettingsButton("Refresh Pets", isLoading: petStore.isLoading) {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    Task {
                        await petStore.refreshPets(codex: codex)
                    }
                }
            }
        }
        .task(id: codex.isConnected) {
            guard codex.isConnected, petStore.isEnabled else {
                return
            }
            await petStore.loadPetsIfNeeded(codex: codex)
            await petStore.loadSelectedPet(codex: codex)
        }
    }

    private var petEnabledBinding: Binding<Bool> {
        Binding(
            get: { petStore.isEnabled },
            set: { isEnabled in
                petStore.setEnabled(isEnabled)
                guard isEnabled else {
                    return
                }
                Task {
                    await petStore.loadPetsIfNeeded(codex: codex)
                    await petStore.loadSelectedPet(codex: codex)
                }
            }
        )
    }

    private var selectedPetBinding: Binding<String> {
        Binding(
            get: { petStore.selectedPet?.id ?? "" },
            set: { selectedID in
                petStore.selectPet(id: selectedID.isEmpty ? nil : selectedID)
                Task {
                    await petStore.loadSelectedPet(codex: codex)
                }
            }
        )
    }
}

private struct SettingsNotificationsCard: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        SettingsCard(title: "Notifications") {
            HStack(spacing: 10) {
                RemodexIcon.image(systemName: "bell.badge")
                    .foregroundStyle(.primary)
                Text("Status")
                Spacer()
                Text(statusLabel)
                    .foregroundStyle(.secondary)
            }

            Text("Used for local alerts when a run finishes while the app is in background.")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)

            if codex.notificationAuthorizationStatus == .notDetermined {
                SettingsButton("Allow notifications") {
                    HapticFeedback.shared.triggerImpactFeedback()
                    Task {
                        await codex.requestNotificationPermission()
                    }
                }
            }

            if codex.notificationAuthorizationStatus == .denied {
                SettingsButton("Open iOS Settings") {
                    HapticFeedback.shared.triggerImpactFeedback()
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
        .task {
            await codex.refreshManagedNotificationRegistrationState()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                return
            }
            Task {
                await codex.refreshManagedNotificationRegistrationState()
            }
        }
    }

    private var statusLabel: String {
        switch codex.notificationAuthorizationStatus {
        case .authorized: "Authorized"
        case .denied: "Denied"
        case .provisional: "Provisional"
        case .ephemeral: "Ephemeral"
        case .notDetermined: "Not requested"
        @unknown default: "Unknown"
        }
    }
}

private struct SettingsGPTAccountCard: View {
    @State private var isShowingMacLoginInfo = false

    var body: some View {
        SettingsCard(title: "ChatGPT voice mode") {
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                isShowingMacLoginInfo = true
            } label: {
                HStack(spacing: 8) {
                    Label("Info", systemImage: "info.circle")
                        .foregroundStyle(.primary)
                    Spacer()
                    RemodexIcon.image(systemName: "chevron.right")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .sheet(isPresented: $isShowingMacLoginInfo) {
            GPTVoiceSetupSheet()
        }
    }
}

private struct SettingsBridgeVersionCard: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.scenePhase) private var scenePhase
    @State private var isUpdatingBridge = false
    @State private var bridgeUpdateMessage: String?
    @State private var bridgeUpdateFailed = false

    var body: some View {
        SettingsCard(title: "Bridge Version") {
            HStack(spacing: 10) {
                Text("Status")
                Spacer()
                SettingsStatusPill(label: versionStatusLabel)
            }

            settingsVersionRow(
                title: "Installed on Device",
                value: installedVersionLabel,
                valueStyle: installedValueStyle
            )

            settingsVersionRow(
                title: "Latest available",
                value: latestVersionLabel,
                valueStyle: .primary
            )

            if let guidance = guidanceText {
                Text(guidance)
                    .font(AppFont.caption())
                    .foregroundStyle(guidanceColor)
            }

            if codex.supportsBridgePackageUpdate {
                SettingsButton(bridgeUpdateButtonTitle, isLoading: isUpdatingBridge) {
                    Task {
                        await updateBridgeFromSettings()
                    }
                }
                .disabled(!codex.isConnected || isUpdatingBridge)
            }

            if let bridgeUpdateMessage {
                Text(bridgeUpdateMessage)
                    .font(AppFont.caption())
                    .foregroundStyle(bridgeUpdateFailed ? .orange : .secondary)
            }
        }
        .task {
            await codex.refreshBridgeVersionState()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await codex.refreshBridgeVersionState()
            }
        }
    }

    private var installedVersionLabel: String {
        normalizedVersion(codex.bridgeInstalledVersion) ?? "Unknown"
    }

    private var latestVersionLabel: String {
        normalizedVersion(codex.latestBridgePackageVersion) ?? "Unknown"
    }

    private var guidanceText: String? {
        guard let installedVersion else {
            return "Connect to a device bridge to read the installed package version."
        }

        guard let latestVersion else {
            return "Installed version detected. The latest published package is unavailable right now."
        }

        if installedVersion == latestVersion {
            return "The installed bridge matches the latest published package."
        }

        if installedVersion.compare(latestVersion, options: .numeric) == .orderedAscending {
            return "A newer Remodex package is available on npm."
        }

        return "This device is running a different build than the current npm latest."
    }

    private var versionStatusLabel: String {
        guard let installedVersion else {
            return "Unknown"
        }

        guard let latestVersion else {
            return "Installed"
        }

        if installedVersion == latestVersion {
            return "Up to date"
        }

        if installedVersion.compare(latestVersion, options: .numeric) == .orderedAscending {
            return "Update available"
        }

        return "Different build"
    }

    private var guidanceColor: Color {
        guard let installedVersion,
              let latestVersion,
              installedVersion.compare(latestVersion, options: .numeric) == .orderedAscending else {
            return .secondary
        }

        return .orange
    }

    private var bridgeUpdateButtonTitle: String {
        if let installedVersion,
           let latestVersion,
           installedVersion.compare(latestVersion, options: .numeric) == .orderedAscending {
            return "Update Bridge on Device"
        }

        return "Reinstall Bridge on Device"
    }

    private var installedValueStyle: Color {
        guard let installedVersion,
              let latestVersion,
              installedVersion.compare(latestVersion, options: .numeric) == .orderedAscending else {
            return .primary
        }

        return .orange
    }

    private var installedVersion: String? {
        normalizedVersion(codex.bridgeInstalledVersion)
    }

    private var latestVersion: String? {
        normalizedVersion(codex.latestBridgePackageVersion)
    }

    private func updateBridgeFromSettings() async {
        guard codex.isConnected else {
            bridgeUpdateFailed = true
            bridgeUpdateMessage = "Connect to your paired device first."
            return
        }

        guard !isUpdatingBridge else {
            return
        }

        isUpdatingBridge = true
        bridgeUpdateMessage = nil
        bridgeUpdateFailed = false

        do {
            let handoffService = DesktopHandoffService(codex: codex)
            try await handoffService.updateBridgePackageAndRestart()
            bridgeUpdateFailed = false
            bridgeUpdateMessage = "Bridge updated. Reconnecting after restart..."
        } catch {
            bridgeUpdateFailed = true
            bridgeUpdateMessage = error.localizedDescription
        }

        isUpdatingBridge = false
    }

    private func normalizedVersion(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }

    private func settingsVersionRow(title: String, value: String, valueStyle: Color) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer()
            Text(value)
                .font(AppFont.mono(.subheadline))
                .foregroundStyle(valueStyle)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }
}

private struct SettingsArchivedChatsCard: View {
    @Environment(CodexService.self) private var codex

    private var archivedCount: Int {
        codex.threads.filter { $0.syncState == .archivedLocal }.count
    }

    var body: some View {
        SettingsCard(title: "Archived Chats") {
            NavigationLink {
                ArchivedChatsView()
            } label: {
                HStack {
                    RemodexIcon.label("Archived Chats", systemName: "archivebox")
                    Spacer()
                    if archivedCount > 0 {
                        Text("\(archivedCount)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environment(CodexService())
    }
}
