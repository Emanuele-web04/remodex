// FILE: TerminalRouteChrome.swift
// Purpose: Navigation title, accessory key bar, and empty-state chrome for the terminal route.
// Layer: View Component
// Exports: TerminalRouteTitle, TerminalRouteAccessoryBar, TerminalRouteUnavailableView
// Depends on: SwiftUI, RemodexTerminalTheme, TerminalUIModels, AdaptiveGlassModifier

import SwiftUI

// MARK: - Navigation title

struct TerminalRouteTitle: View {
    let topLine: String
    let bottomLine: String
    let theme: RemodexTerminalTheme

    var body: some View {
        VStack(spacing: 1) {
            Text(topLine)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hexString: theme.foreground))
                .lineLimit(1)

            Text(bottomLine)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(hexString: theme.mutedForeground))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: 240)
    }
}

// MARK: - Accessory bar

/// Bottom accessory rail above the keyboard.
///
/// Layout: horizontally scrollable key clusters with fixed keyboard and D-pad controls overlaid.
/// The bar background is transparent — the terminal background reads through, and each cluster /
/// circle has its own native Liquid Glass material (with `.thinMaterial` fallback on iOS < 26).
/// The scroll view spans under the fixed controls so narrow phones keep all command keys reachable.
struct TerminalRouteAccessoryBar: View {
    let clusters: [TerminalToolbarCluster]
    let pendingModifier: TerminalPendingModifier?
    let theme: RemodexTerminalTheme
    let isEnabled: Bool
    let onAction: (TerminalToolbarAction) -> Void
    let onSelectModifier: (TerminalPendingModifier) -> Void
    let onDismissKeyboard: () -> Void
    let onDirectionalInput: (String) -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(clusters) { cluster in
                        TerminalRouteKeyCluster(
                            actions: cluster.actions,
                            pendingModifier: pendingModifier,
                            theme: theme,
                            isEnabled: isEnabled,
                            onAction: onAction,
                            onSelectModifier: onSelectModifier
                        )
                        .id(cluster.id)
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 116)
                .frame(minHeight: remodexTerminalAccessoryHeight, alignment: .leading)
            }
            .scrollClipDisabled(true)

            HStack(spacing: 6) {
                TerminalRouteCircleAction(
                    systemImage: "keyboard.chevron.compact.down",
                    accessibilityLabel: "Dismiss keyboard",
                    theme: theme,
                    isEnabled: true,
                    action: onDismissKeyboard
                )

                TerminalRouteDPadControl(
                    theme: theme,
                    isEnabled: isEnabled,
                    onInput: onDirectionalInput
                )
            }
            .padding(.trailing, 10)
        }
        .padding(.vertical, 4)
        .frame(minHeight: remodexTerminalAccessoryHeight)
        .background(Color.clear)
        // Floating pill: shows the user that a modifier is armed for the next
        // keystroke. The previous design relied on a subtle text-color change
        // inside the modifier capsule, which was easy to miss.
        .overlay(alignment: .topLeading) {
            if let pendingModifier {
                TerminalArmedModifierBadge(modifier: pendingModifier, theme: theme)
                    .padding(.leading, 16)
                    .offset(y: -22)
                    .transition(
                        .move(edge: .bottom)
                            .combined(with: .opacity)
                            .animation(.spring(response: 0.28, dampingFraction: 0.82))
                    )
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: pendingModifier)
    }
}

// MARK: - Armed modifier badge

private struct TerminalArmedModifierBadge: View {
    let modifier: TerminalPendingModifier
    let theme: RemodexTerminalTheme

    private var accent: Color {
        Color(hexString: theme.palette.indices.contains(10) ? theme.palette[10] : theme.foreground)
    }

    var body: some View {
        HStack(spacing: 5) {
            RemodexIcon.image(systemName: modifier.menuSymbolName)
                .font(.system(size: 9, weight: .bold))
            Text("\(modifier.menuTitle.uppercased()) armed")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.4)
        }
        .foregroundStyle(Color(hexString: theme.background))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(accent)
                .shadow(color: accent.opacity(0.45), radius: 6, x: 0, y: 2)
        )
        .accessibilityHidden(true)
    }
}

// MARK: - Key cluster (capsule glass)

/// A run of related keys rendered as a single capsule of glass with vertical hairline dividers
/// between adjacent keys. Touch targets are full-height segments so the cluster reads as one
/// pill from the screenshot's reference design but each segment still gets independent taps.
private struct TerminalRouteKeyCluster: View {
    let actions: [TerminalToolbarAction]
    let pendingModifier: TerminalPendingModifier?
    let theme: RemodexTerminalTheme
    let isEnabled: Bool
    let onAction: (TerminalToolbarAction) -> Void
    let onSelectModifier: (TerminalPendingModifier) -> Void

    private var dividerColor: Color {
        Color(hexString: theme.foreground).opacity(0.12)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                TerminalRouteKeySegment(
                    action: action,
                    isActive: action.modifier == pendingModifier && action.isModifier,
                    theme: theme,
                    isEnabled: isEnabled,
                    onAction: onAction,
                    onSelectModifier: onSelectModifier
                )

                if index < actions.count - 1 {
                    Rectangle()
                        .fill(dividerColor)
                        .frame(width: 1, height: 20)
                }
            }
        }
        .frame(height: 38)
        .adaptiveGlass(.regular, in: Capsule())
        .contentShape(Capsule())
    }
}

// MARK: - Single key segment

private struct TerminalRouteKeySegment: View {
    let action: TerminalToolbarAction
    let isActive: Bool
    let theme: RemodexTerminalTheme
    let isEnabled: Bool
    let onAction: (TerminalToolbarAction) -> Void
    let onSelectModifier: (TerminalPendingModifier) -> Void

    private var activeAccent: Color {
        Color(hexString: theme.palette.indices.contains(10) ? theme.palette[10] : theme.foreground)
    }

    private var textColor: Color {
        if !isEnabled { return Color(hexString: theme.foreground).opacity(0.35) }
        return isActive ? activeAccent : Color(hexString: theme.foreground)
    }

    private var segmentWidth: CGFloat {
        // Modifiers need extra room for the chevron affordance that signals the picker.
        if action.isModifier { return 56 }
        if action.label.count <= 1 { return 32 }
        if action.label.count <= 3 { return 40 }
        if action.label.contains(" ") { return 52 }
        return 44
    }

    var body: some View {
        if action.isModifier {
            modifierSegment
        } else {
            sendSegment
        }
    }

    // Tap = toggle pending modifier; long-press surfaces the system menu so the
    // user can switch between cmd/shift/alt/ctrl without remembering a gesture.
    private var modifierSegment: some View {
        Menu {
            Picker(
                selection: Binding<TerminalPendingModifier>(
                    get: { action.modifier ?? .ctrl },
                    set: { newValue in
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        onSelectModifier(newValue)
                    }
                ),
                label: Text("Modifier key")
            ) {
                ForEach(TerminalPendingModifier.allCases, id: \.self) { modifier in
                    RemodexIcon.menuLabel(modifier.menuTitle, systemName: modifier.menuSymbolName)
                        .tag(modifier)
                }
            }
            .pickerStyle(.inline)
        } label: {
            segmentLabel
        } primaryAction: {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            onAction(action)
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("\(action.label) modifier")
        .accessibilityHint("Tap to arm. Long-press to choose between cmd, shift, alt, and ctrl.")
    }

    private var sendSegment: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            onAction(action)
        } label: {
            segmentLabel
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(action.label)
    }

    private var segmentLabel: some View {
        HStack(spacing: 3) {
            Text(action.label)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(textColor)
            if action.isModifier {
                RemodexIcon.image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(textColor.opacity(0.75))
            }
        }
        .frame(width: segmentWidth)
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 2)
        .background(
            Capsule()
                .fill(isActive ? activeAccent.opacity(0.22) : Color.clear)
                .padding(.vertical, 4)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Circle action (glass)

private struct TerminalRouteCircleAction: View {
    let systemImage: String
    let accessibilityLabel: String
    let theme: RemodexTerminalTheme
    let isEnabled: Bool
    var isHighlighted: Bool = false
    let action: () -> Void

    private var iconColor: Color {
        if !isEnabled { return Color(hexString: theme.foreground).opacity(0.35) }
        if isHighlighted {
            let accent = theme.palette.indices.contains(10) ? theme.palette[10] : theme.foreground
            return Color(hexString: accent)
        }
        return Color(hexString: theme.foreground)
    }

    var body: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            action()
        } label: {
            RemodexIcon.image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 40, height: 40)
                .adaptiveGlass(.regular, in: Circle())
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Circular DPad controller

private enum TerminalDPadDirection {
    case up
    case down
    case left
    case right

    var input: String {
        switch self {
        case .up: return "\u{1B}[A"
        case .down: return "\u{1B}[B"
        case .left: return "\u{1B}[D"
        case .right: return "\u{1B}[C"
        }
    }

    var repeatIntervalNanoseconds: UInt64 {
        switch self {
        case .up, .down:
            return 105_000_000
        case .left, .right:
            return 80_000_000
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        }
    }

    var symbolName: String {
        switch self {
        case .up: return "chevron.up"
        case .down: return "chevron.down"
        case .left: return "chevron.left"
        case .right: return "chevron.right"
        }
    }
}

private struct TerminalRouteDPadControl: View {
    private static let controlSize: CGFloat = 56
    private static let deadZoneRadius: CGFloat = 9
    private static let centerCircleSize: CGFloat = 18

    let theme: RemodexTerminalTheme
    let isEnabled: Bool
    let onInput: (String) -> Void

    @State private var activeDirection: TerminalDPadDirection?
    @State private var repeatTask: Task<Void, Never>?
    @State private var pressGeneration = 0
    @State private var joystickOffset: CGSize = .zero
    @State private var hasMovedOutOfDeadZone = false

    private var foregroundColor: Color {
        isEnabled ? Color(hexString: theme.foreground) : Color(hexString: theme.foreground).opacity(0.35)
    }

    private var activeAccent: Color {
        Color(hexString: theme.palette.indices.contains(10) ? theme.palette[10] : theme.foreground)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Circle()
                    .stroke(Color(hexString: theme.foreground).opacity(0.18), lineWidth: 1)

                DPadArrows(
                    activeDirection: activeDirection,
                    foreground: foregroundColor,
                    activeForeground: Color(hexString: theme.background),
                    accent: activeAccent
                )

                Circle()
                    .fill(Color(hexString: theme.background).opacity(0.68))
                    .frame(width: Self.centerCircleSize, height: Self.centerCircleSize)
                    .overlay {
                        Circle()
                            .stroke(
                                activeDirection == nil
                                    ? foregroundColor.opacity(0.22)
                                    : activeAccent.opacity(0.72),
                                lineWidth: 1
                            )
                    }
                    .offset(joystickOffset)
                    .animation(.interactiveSpring(response: 0.16, dampingFraction: 0.78), value: joystickOffset)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .adaptiveGlass(.regular, in: Circle())
            .contentShape(Circle())
            // `minimumDistance: 0` is what makes single taps on the visible
            // chevrons actually emit an arrow keystroke. Before, the gesture
            // required 8pt of drag, so users tapping the icons got silence.
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard isEnabled else {
                            endPress()
                            return
                        }
                        guard let direction = direction(for: value.location, in: proxy.size) else {
                            // Sliding back to center releases the joystick mid-press.
                            if hasMovedOutOfDeadZone {
                                endPress()
                            }
                            return
                        }
                        hasMovedOutOfDeadZone = true
                        joystickOffset = offset(for: value.location, in: proxy.size)
                        beginPress(direction)
                    }
                    .onEnded { _ in
                        endPress()
                    }
            )
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityLabel("Arrow key controller")
            .accessibilityHint("Tap a direction to send one arrow key. Hold to repeat. Drag to switch directions.")
        }
        .frame(width: Self.controlSize, height: Self.controlSize)
        .onDisappear {
            endPress()
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                endPress()
            }
        }
    }

    private func direction(for location: CGPoint, in size: CGSize) -> TerminalDPadDirection? {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = location.x - center.x
        let dy = location.y - center.y
        let distance = hypot(dx, dy)
        guard distance > Self.deadZoneRadius else { return nil }
        if abs(dx) > abs(dy) {
            return dx < 0 ? .left : .right
        }
        return dy < 0 ? .up : .down
    }

    private func offset(for location: CGPoint, in size: CGSize) -> CGSize {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = location.x - center.x
        let dy = location.y - center.y
        let distance = max(1, hypot(dx, dy))
        let maxOffset: CGFloat = 10
        let scale = min(maxOffset / distance, 1)
        return CGSize(width: dx * scale, height: dy * scale)
    }

    private func beginPress(_ direction: TerminalDPadDirection) {
        guard activeDirection != direction else { return }
        repeatTask?.cancel()
        activeDirection = direction
        pressGeneration += 1
        let generation = pressGeneration
        send(direction, haptic: true)

        repeatTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            while !Task.isCancelled,
                  activeDirection == direction,
                  pressGeneration == generation {
                send(direction, haptic: false)
                try? await Task.sleep(nanoseconds: direction.repeatIntervalNanoseconds)
            }
        }
    }

    private func endPress() {
        pressGeneration += 1
        repeatTask?.cancel()
        repeatTask = nil
        hasMovedOutOfDeadZone = false
        withAnimation(.easeOut(duration: 0.12)) {
            activeDirection = nil
            joystickOffset = .zero
        }
    }

    private func send(_ direction: TerminalDPadDirection, haptic: Bool) {
        if haptic {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
        }
        onInput(direction.input)
    }
}

private struct DPadArrows: View {
    let activeDirection: TerminalDPadDirection?
    let foreground: Color
    let activeForeground: Color
    let accent: Color

    var body: some View {
        ZStack {
            arrow(.up).offset(y: -16)
            arrow(.down).offset(y: 16)
            arrow(.left).offset(x: -16)
            arrow(.right).offset(x: 16)
        }
        .font(.system(size: 8, weight: .bold))
    }

    private func arrow(_ direction: TerminalDPadDirection) -> some View {
        ZStack {
            Circle()
                .fill(activeDirection == direction ? accent.opacity(0.72) : Color.white.opacity(0.08))
                .frame(width: 16, height: 16)

            RemodexIcon.image(systemName: direction.symbolName)
                .foregroundStyle(activeDirection == direction ? activeForeground : foreground.opacity(0.82))
        }
    }
}

// MARK: - Empty / unavailable state

struct TerminalRouteUnavailableView: View {
    let title: String
    let detail: String
    let theme: RemodexTerminalTheme
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            RemodexIcon.image(systemName: "terminal")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color(hexString: theme.foreground))

            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color(hexString: theme.foreground))

            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Color(hexString: theme.mutedForeground))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Button("SSH connection", action: action)
                .font(.system(size: 12, weight: .bold))
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hexString: theme.background))
    }
}
