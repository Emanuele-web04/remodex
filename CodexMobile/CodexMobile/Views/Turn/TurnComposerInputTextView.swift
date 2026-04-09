// FILE: TurnComposerInputTextView.swift
// Purpose: UIViewRepresentable wrapper for the composer text input and paste-image interception.
// Layer: View Component
// Exports: TurnComposerInputTextView, TurnComposerPasteInterceptingTextView
// Depends on: SwiftUI, UIKit, TurnComposerRuntimeMenuBuilder

import SwiftUI
import UIKit

struct TurnComposerInputTextView: UIViewRepresentable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var text: String
    @Binding var isFocused: Bool
    let isEditable: Bool
    @Binding var dynamicHeight: CGFloat
    let runtimeState: TurnComposerRuntimeState?
    let runtimeActions: TurnComposerRuntimeActions
    let onPasteImageData: ([Data]) -> Void

    private let minVisibleLines: CGFloat = 1
    private let maxVisibleLines: CGFloat = 4

    func makeUIView(context: Context) -> TurnComposerPasteInterceptingTextView {
        let textView = TurnComposerPasteInterceptingTextView(frame: .zero, textContainer: nil)
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = composerUIFont()
        textView.textColor = UIColor.label
        textView.typingAttributes[.font] = composerUIFont()
        textView.typingAttributes[.foregroundColor] = UIColor.label
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.autocorrectionType = .default
        textView.autocapitalizationType = .sentences
        textView.isScrollEnabled = false
        textView.showsVerticalScrollIndicator = false
        textView.alwaysBounceVertical = false
        // Keep drags inside the composer dedicated to editing and internal scrolling.
        textView.keyboardDismissMode = .none
        textView.onPasteImageData = onPasteImageData
        textView.runtimeState = runtimeState
        textView.runtimeActions = runtimeActions
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.accessibilityIdentifier = "turn.composer.input"
        context.coordinator.syncFocusIfNeeded(
            for: textView,
            shouldBeFocused: isFocused,
            isEditable: isEditable
        )
        context.coordinator.updateHeight(for: textView)
        return textView
    }

    func updateUIView(_ uiView: TurnComposerPasteInterceptingTextView, context: Context) {
        let textChanged = uiView.text != text
        if textChanged {
            uiView.text = text
        }

        context.coordinator.updateBindings(
            text: $text,
            isFocused: $isFocused,
            dynamicHeight: $dynamicHeight
        )
        uiView.isEditable = isEditable
        uiView.isSelectable = true
        uiView.font = composerUIFont()
        uiView.typingAttributes[.font] = composerUIFont()
        uiView.typingAttributes[.foregroundColor] = UIColor.label
        uiView.adjustsFontForContentSizeCategory = true
        uiView.textContainer.widthTracksTextView = true
        // Preserve internal scrolling without letting composer drags dismiss the keyboard.
        uiView.keyboardDismissMode = .none
        uiView.onPasteImageData = onPasteImageData
        uiView.runtimeState = runtimeState
        uiView.runtimeActions = runtimeActions
        uiView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        context.coordinator.syncFocusIfNeeded(
            for: uiView,
            shouldBeFocused: isFocused,
            isEditable: isEditable
        )
        context.coordinator.updateHeight(for: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isFocused: $isFocused,
            dynamicHeight: $dynamicHeight,
            minVisibleLines: minVisibleLines,
            maxVisibleLines: maxVisibleLines
        )
    }

    // Keeps the composer aligned with the app's normal body sizing instead of
    // the smaller ad hoc size that made the input feel visually detached.
    private func composerUIFont() -> UIFont {
        // Read the SwiftUI environment so UIKit gets refreshed when Dynamic Type changes.
        let _ = dynamicTypeSize
        return AppFont.uiFont(size: 15, textStyle: .body)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private var text: Binding<String>
        private var isFocused: Binding<Bool>
        private var dynamicHeight: Binding<CGFloat>
        private let minVisibleLines: CGFloat
        private let maxVisibleLines: CGFloat
        private var lastFocusBindingValue: Bool
        private var pendingHeightValue: CGFloat?
        private var isHeightCommitScheduled = false

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            dynamicHeight: Binding<CGFloat>,
            minVisibleLines: CGFloat,
            maxVisibleLines: CGFloat
        ) {
            self.text = text
            self.isFocused = isFocused
            self.dynamicHeight = dynamicHeight
            self.minVisibleLines = minVisibleLines
            self.maxVisibleLines = maxVisibleLines
            self.lastFocusBindingValue = isFocused.wrappedValue
        }

        func updateBindings(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            dynamicHeight: Binding<CGFloat>
        ) {
            self.text = text
            self.isFocused = isFocused
            self.dynamicHeight = dynamicHeight
        }

        func textViewDidChange(_ textView: UITextView) {
            if text.wrappedValue != textView.text {
                text.wrappedValue = textView.text
            }
            updateHeight(for: textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !isFocused.wrappedValue {
                isFocused.wrappedValue = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if isFocused.wrappedValue {
                isFocused.wrappedValue = false
            }
        }

        fileprivate func updateHeight(for textView: UITextView) {
            textView.layoutIfNeeded()
            textView.layoutManager.ensureLayout(for: textView.textContainer)
            let lineHeight = (textView.font ?? UIFont.preferredFont(forTextStyle: .body)).lineHeight
            let minHeight = lineHeight * minVisibleLines
            let maxHeight = lineHeight * maxVisibleLines
            let targetWidth = max(textView.bounds.width, textView.textContainer.size.width, 1)
            let fitSize = CGSize(width: targetWidth, height: .greatestFiniteMagnitude)
            var measured = textView.sizeThatFits(fitSize).height
            let shouldScroll = measured > maxHeight + 0.5
            if textView.isScrollEnabled != shouldScroll {
                textView.isScrollEnabled = shouldScroll
                textView.alwaysBounceVertical = shouldScroll
                textView.showsVerticalScrollIndicator = shouldScroll
                textView.invalidateIntrinsicContentSize()
                measured = textView.sizeThatFits(fitSize).height
            }
            let clamped = min(max(measured, minHeight), maxHeight)
            normalizeViewport(in: textView, shouldScroll: shouldScroll)

            if abs(dynamicHeight.wrappedValue - clamped) > 0.5 {
                scheduleHeightCommit(clamped)
            }

            keepCaretVisible(in: textView)
        }

        // Coalesces repeated text-layout height writes so SwiftUI sees at most one
        // composer-height update per run-loop turn instead of several per frame.
        private func scheduleHeightCommit(_ height: CGFloat) {
            pendingHeightValue = height
            guard !isHeightCommitScheduled else { return }

            isHeightCommitScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isHeightCommitScheduled = false

                guard let pendingHeight = self.pendingHeightValue else { return }
                self.pendingHeightValue = nil

                if abs(self.dynamicHeight.wrappedValue - pendingHeight) > 0.5 {
                    self.dynamicHeight.wrappedValue = pendingHeight
                }
            }
        }

        // Keeps the newest typed line visible once the composer switches from growing to internal scrolling.
        private func keepCaretVisible(in textView: UITextView) {
            guard textView.isScrollEnabled else { return }
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.layoutIfNeeded()
                guard let selectionEnd = textView.selectedTextRange?.end else { return }
                let caretRect = textView.caretRect(for: selectionEnd).insetBy(dx: 0, dy: -8)
                textView.scrollRectToVisible(caretRect, animated: false)
            }
        }

        // Resets/clamps the text viewport after Return inserts can nudge UITextView
        // into a stale offset even when the full composer content still fits.
        private func normalizeViewport(in textView: UITextView, shouldScroll: Bool) {
            let adjustedInset = textView.adjustedContentInset
            let minOffset = CGPoint(x: -adjustedInset.left, y: -adjustedInset.top)

            guard shouldScroll else {
                guard
                    abs(textView.contentOffset.x - minOffset.x) > 0.5
                        || abs(textView.contentOffset.y - minOffset.y) > 0.5
                else {
                    return
                }
                textView.setContentOffset(minOffset, animated: false)
                return
            }

            let maxYOffset = max(
                minOffset.y,
                textView.contentSize.height - textView.bounds.height + adjustedInset.bottom
            )
            let clampedOffset = CGPoint(
                x: minOffset.x,
                y: min(max(textView.contentOffset.y, minOffset.y), maxYOffset)
            )

            guard
                abs(textView.contentOffset.x - clampedOffset.x) > 0.5
                    || abs(textView.contentOffset.y - clampedOffset.y) > 0.5
            else {
                return
            }
            textView.setContentOffset(clampedOffset, animated: false)
        }

        fileprivate func syncFocusIfNeeded(
            for textView: UITextView,
            shouldBeFocused: Bool,
            isEditable: Bool
        ) {
            let focusBindingDidChange = shouldBeFocused != lastFocusBindingValue
            lastFocusBindingValue = shouldBeFocused

            // Only drive focus changes when the binding actually flipped.
            // Reacting on every updateUIView when the value is merely "still true"
            // causes a becomeFirstResponder → didBeginEditing → binding write →
            // updateUIView → becomeFirstResponder loop that drops the keyboard.
            guard focusBindingDidChange else { return }

            if shouldBeFocused && isEditable {
                guard !textView.isFirstResponder else { return }
                DispatchQueue.main.async {
                    textView.becomeFirstResponder()
                }
            } else if !shouldBeFocused || !isEditable {
                guard textView.isFirstResponder else { return }
                DispatchQueue.main.async {
                    textView.resignFirstResponder()
                }
            }
        }
    }
}

// Internal (not fileprivate) because UIViewRepresentable protocol methods expose the type.
// Only used by TurnComposerInputTextView in this file.
final class TurnComposerPasteInterceptingTextView: UITextView {
    var onPasteImageData: (([Data]) -> Void)?
    var runtimeState: TurnComposerRuntimeState?
    var runtimeActions: TurnComposerRuntimeActions?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // Prevent horizontal expansion when isScrollEnabled is toggled to false.
    // Without this, SwiftUI uses the full text width as the ideal size.
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        guard !isScrollEnabled else { return }

        let pinnedOffset = CGPoint(
            x: -adjustedContentInset.left,
            y: -adjustedContentInset.top
        )
        guard
            abs(contentOffset.x - pinnedOffset.x) > 0.5
                || abs(contentOffset.y - pinnedOffset.y) > 0.5
        else {
            return
        }
        contentOffset = pinnedOffset
    }

    // Adds the shared runtime controls directly into the text edit menu.
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)

        guard let runtimeState, let runtimeActions else {
            return
        }

        guard let runtimeMenu = TurnComposerRuntimeMenuBuilder(
            runtimeState: runtimeState,
            runtimeActions: runtimeActions
        ).makeRuntimeMenu() else {
            return
        }

        builder.insertChild(runtimeMenu, atEndOfMenu: .standardEdit)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(UIResponderStandardEditActions.paste(_:)) {
            let pb = UIPasteboard.general
            if pb.hasImages { return true }
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = UIPasteboard.general
        let imageDataItems = imageDataFromPasteboard(pasteboard)
        if !imageDataItems.isEmpty {
            onPasteImageData?(imageDataItems)
            if pasteboard.hasStrings {
                super.paste(sender)
            }
            return
        }
        super.paste(sender)
    }

    private static let maxIntakeDimension: CGFloat = 1600
    private static let intakeCompressionQuality: CGFloat = 0.8

    private func imageDataFromPasteboard(_ pasteboard: UIPasteboard) -> [Data] {
        var imageDataItems: [Data] = []

        if let images = pasteboard.images, !images.isEmpty {
            imageDataItems = images.compactMap { Self.downscaledJPEGData(from: $0) }
        } else if let image = pasteboard.image {
            if let data = Self.downscaledJPEGData(from: image) {
                imageDataItems = [data]
            }
        } else {
            let fallbackTypeIDs = [
                "public.heic",
                "public.jpeg",
                "public.png",
                "public.tiff",
                "com.compuserve.gif"
            ]

            for typeID in fallbackTypeIDs {
                if let data = pasteboard.data(forPasteboardType: typeID), !data.isEmpty {
                    imageDataItems.append(data)
                }
            }
        }

        return imageDataItems
    }

    /// Downscales a UIImage to `maxIntakeDimension` before encoding to JPEG,
    /// so full-resolution data never enters the attachment pipeline.
    private static func downscaledJPEGData(from image: UIImage) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let longestSide = max(size.width, size.height)
        let scale = min(1, maxIntakeDimension / longestSide)

        if scale < 1 {
            let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
            }
            return resized.jpegData(compressionQuality: intakeCompressionQuality)
        }

        return image.jpegData(compressionQuality: intakeCompressionQuality)
    }
}
