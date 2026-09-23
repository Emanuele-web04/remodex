import SwiftUI

struct RuntimeProviderIcon: View {
    let provider: CodexRuntimeProvider
    var size: CGFloat = 20
    var color: Color = .primary

    var body: some View {
        Image(provider == .opencode ? "provider-opencode" : "provider-codex")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            // The Codex mark occupies about 65% of its SVG canvas; OpenCode's
            // occupies about 83% vertically. Equalize the visible heights.
            .scaleEffect(provider == .codex ? 1.3 : 1)
            .foregroundStyle(color)
            .accessibilityLabel(provider == .opencode ? "OpenCode" : "Codex")
    }
}
