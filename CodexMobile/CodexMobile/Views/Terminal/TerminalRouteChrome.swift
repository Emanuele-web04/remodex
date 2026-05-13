// FILE: TerminalRouteChrome.swift
// Purpose: Navigation title, accessory key bar, and empty-state chrome for the terminal route.
// Layer: View Component
// Exports: TerminalRouteTitle, TerminalRouteAccessoryBar, TerminalRouteUnavailableView
// Depends on: SwiftUI, RemodexTerminalTheme, TerminalUIModels, AdaptiveGlassModifier

import SwiftUI

// MARK: - Glass back button

/// Replacement for the system back chevron, rendered as a glass circle so it
/// reads against the now-transparent terminal nav bar.
struct TerminalGlassBackButton: View {
    let theme: RemodexTerminalTheme
    let action: () -> Void

    var body: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            action()
        } label: {
            Image(systemName: "chevron.backward")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(hexString: theme.foreground))
                .frame(width: 36, height: 36)
                .adaptiveGlass(.regular, in: Circle())
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel("Back")
    }
}

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
/// Layout: `[ compact scrollable clusters ]  [ keyboard-dismiss circle ]  [ DPad controller ]`
/// The bar background is transparent — the terminal background reads through, and each cluster /
/// circle has its own native Liquid Glass material (with `.thinMaterial` fallback on iOS < 26).
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
        HStack(spacing: 6) {
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
                .padding(.horizontal, 1)
                .padding(.vertical, 3)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)

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
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minHeight: remodexTerminalAccessoryHeight)
        .background(Color.clear)
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

    @State private var isShowingModifierPicker = false

    private var activeAccent: Color {
        Color(hexString: theme.palette.indices.contains(10) ? theme.palette[10] : theme.foreground)
    }

    private var textColor: Color {
        if !isEnabled { return Color(hexString: theme.foreground).opacity(0.35) }
        return isActive ? activeAccent : Color(hexString: theme.foreground)
    }

    private var segmentWidth: CGFloat {
        if action.label.count <= 1 { return 32 }
        if action.label.count <= 3 { return 40 }
        if action.label.contains(" ") { return 52 }
        return 44
    }

    var body: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            onAction(action)
        } label: {
            Text(action.label)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(textColor)
                .frame(width: segmentWidth)
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(action.label)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35)
                .onEnded { _ in
                    guard action.modifier != nil, isEnabled else { return }
                    HapticFeedback.shared.triggerImpactFeedback(style: .medium)
                    isShowingModifierPicker = true
                }
        )
        .popover(isPresented: $isShowingModifierPicker, attachmentAnchor: .point(.top), arrowEdge: .bottom) {
            TerminalModifierPicker(
                selectedModifier: action.modifier ?? .ctrl,
                theme: theme,
                onSelect: { modifier in
                    onSelectModifier(modifier)
                    isShowingModifierPicker = false
                }
            )
            .presentationCompactAdaptation(.popover)
        }
    }
}

private struct TerminalModifierPicker: View {
    let selectedModifier: TerminalPendingModifier
    let theme: RemodexTerminalTheme
    let onSelect: (TerminalPendingModifier) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(TerminalPendingModifier.allCases, id: \.self) { modifier in
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    onSelect(modifier)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: modifier.menuSymbolName)
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 24)
                        Text(modifier.menuTitle)
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 54, alignment: .trailing)
                    }
                    .foregroundStyle(modifier == selectedModifier
                        ? Color(hexString: theme.foreground)
                        : Color(hexString: theme.foreground).opacity(0.62))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        modifier == selectedModifier
                            ? Color(hexString: theme.palette.indices.contains(10) ? theme.palette[10] : theme.foreground).opacity(0.18)
                            : Color.clear,
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(width: 190)
        .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
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
            Image(systemName: systemImage)
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
    let theme: RemodexTerminalTheme
    let isEnabled: Bool
    let onInput: (String) -> Void

    @State private var activeDirection: TerminalDPadDirection?
    @State private var repeatTask: Task<Void, Never>?
    @State private var pressGeneration = 0
    @State private var joystickOffset: CGSize = .zero

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
                    .frame(width: 16, height: 16)
                    .overlay {
                        Circle()
                            .stroke(activeDirection == nil ? foregroundColor.opacity(0.22) : activeAccent.opacity(0.72), lineWidth: 1)
                    }
                    .offset(joystickOffset)
                    .animation(.interactiveSpring(response: 0.16, dampingFraction: 0.78), value: joystickOffset)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .adaptiveGlass(.regular, in: Circle())
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .local)
                    .onChanged { value in
                        guard isEnabled else {
                            endPress()
                            return
                        }
                        guard let direction = direction(for: value.location, in: proxy.size) else {
                            // Returning to the center dead-zone releases the joystick.
                            endPress()
                            return
                        }
                        joystickOffset = offset(for: value.location, in: proxy.size)
                        beginPress(direction)
                    }
                    .onEnded { _ in
                        endPress()
                    }
            )
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityLabel("Arrow key controller")
            .accessibilityHint("Drag from the center and hold a direction to send terminal arrow keys")
        }
        .frame(width: 50, height: 50)
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
        guard distance > 13 else { return nil }
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
        let maxOffset: CGFloat = 9
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
            arrow(.up).offset(y: -14)
            arrow(.down).offset(y: 14)
            arrow(.left).offset(x: -14)
            arrow(.right).offset(x: 14)
        }
        .font(.system(size: 8, weight: .bold))
    }

    private func arrow(_ direction: TerminalDPadDirection) -> some View {
        ZStack {
            Circle()
                .fill(activeDirection == direction ? accent.opacity(0.72) : Color.white.opacity(0.08))
                .frame(width: 16, height: 16)

            Image(systemName: direction.symbolName)
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
            Image(systemName: "terminal")
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
