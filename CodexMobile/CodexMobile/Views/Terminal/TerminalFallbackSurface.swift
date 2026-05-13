// FILE: TerminalFallbackSurface.swift
// Purpose: Text-based terminal fallback used when the native Ghostty renderer cannot initialize.
// Layer: View Component
// Exports: TerminalFallbackSurface
// Depends on: SwiftUI, RemodexTerminalModels, RemodexTerminalTheme

import SwiftUI

struct TerminalFallbackSurface: View {
    let snapshot: RemodexTerminalSnapshot
    let fontSize: CGFloat
    let theme: RemodexTerminalTheme
    let isRunning: Bool
    let onInput: (String) -> Void
    let onResize: (Int, Int) -> Void

    @State private var input = ""

    private var statusLabel: String {
        isRunning ? "Native terminal unavailable. Using text fallback." : "Open terminal to start a shell."
    }

    private var renderedBuffer: String {
        let text = String(decoding: snapshot.bufferData, as: UTF8.self)
        return text.isEmpty ? "$ " : text
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                TerminalFallbackBuffer(
                    statusLabel: statusLabel,
                    renderedBuffer: renderedBuffer,
                    fontSize: fontSize,
                    theme: theme
                )

                TerminalFallbackInputBar(
                    input: $input,
                    theme: theme,
                    isRunning: isRunning,
                    onSubmit: sendInput,
                    onInterrupt: { onInput("\u{3}") }
                )
            }
            .background(Color(hexString: theme.background))
            .onAppear {
                emitResize(for: proxy.size)
            }
            .onChange(of: proxy.size) { _, size in
                emitResize(for: size)
            }
        }
    }

    private func sendInput() {
        guard !input.isEmpty else { return }
        onInput("\(input)\n")
        input = ""
    }

    private func emitResize(for size: CGSize) {
        let cellWidth = max(fontSize * 0.62, 1)
        let cellHeight = max(fontSize * 1.35, 1)
        onResize(
            max(20, min(400, Int(size.width / cellWidth))),
            max(5, min(200, Int(size.height / cellHeight)))
        )
    }
}

private struct TerminalFallbackBuffer: View {
    let statusLabel: String
    let renderedBuffer: String
    let fontSize: CGFloat
    let theme: RemodexTerminalTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(statusLabel)
                .font(.system(size: 11))
                .foregroundStyle(Color(hexString: theme.mutedForeground))

            ScrollView(.vertical, showsIndicators: false) {
                Text(renderedBuffer)
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(Color(hexString: theme.foreground))
                    .lineSpacing(max(0, round(fontSize * 0.35) - 1))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct TerminalFallbackInputBar: View {
    @Binding var input: String

    let theme: RemodexTerminalTheme
    let isRunning: Bool
    let onSubmit: () -> Void
    let onInterrupt: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("type and press return", text: $input)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color(hexString: theme.foreground))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(!isRunning)
                .onSubmit(onSubmit)

            Button("Ctrl-C", action: onInterrupt)
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(hexString: theme.border), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(Color(hexString: theme.foreground))
                .disabled(!isRunning)
                .opacity(isRunning ? 1 : 0.35)
        }
        .padding(8)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(hexString: theme.border))
                .frame(height: 1)
        }
    }
}
