// FILE: TurnComposerInputTextView.swift
// Purpose: UIViewRepresentable wrapper for the composer text input and paste-image interception.
// Layer: View Component
// Exports: TurnComposerInputTextView, TurnComposerPasteInterceptingTextView
// Depends on: SwiftUI, UIKit, TurnComposerRuntimeMenuBuilder

import SwiftUI
import UIKit

struct TurnComposerInputTextView: UIViewRepresentable {
    // Shared with the SwiftUI placeholder so empty and typed text start on the same baseline.
    static let textContainerInset = UIEdgeInsets(top: 3, left: 0, bottom: 5, right: 0)

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(UserBubbleColor.storageKey)
    private var userBubbleColorRawValue = UserBubbleColor.defaultStoredRawValue
    @Binding var text: String
    @Binding var isFocused: Bool
    let isEditable: Bool
    @Binding var dynamicHeight: CGFloat
    let mentionedSkillNames: [String]
    let runtimeState: TurnComposerRuntimeState?
    let runtimeActions: TurnComposerRuntimeActions
    let isCollapsed: Bool
    let maxVisibleLines: CGFloat
    let onPasteImageData: ([Data]) -> Void

    private let minVisibleLines: CGFloat = 1
    func makeUIView(context: Context) -> TurnComposerPasteInterceptingTextView {
        let textView = TurnComposerPasteInterceptingTextView(frame: .zero, textContainer: nil)
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = composerUIFont()
        textView.textColor = UIColor.label
        textView.typingAttributes[.font] = composerUIFont()
        textView.typingAttributes[.foregroundColor] = UIColor.label
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = Self.textContainerInset
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
        context.coordinator.updateHeightIfNeeded(for: textView, force: true)
        return textView
    }

    func updateUIView(_ uiView: TurnComposerPasteInterceptingTextView, context: Context) {
        let nextFont = composerUIFont()
        let currentFont = uiView.font
        let fontChanged = currentFont?.fontName != nextFont.fontName
            || abs((currentFont?.pointSize ?? 0) - nextFont.pointSize) > 0.5
        context.coordinator.updateBindings(
            text: $text,
            isFocused: $isFocused,
            dynamicHeight: $dynamicHeight
        )
        let maxVisibleLinesChanged = context.coordinator.updateMaxVisibleLines(maxVisibleLines)
        let expandedAfterCollapse = context.coordinator.noteCollapsedState(isCollapsed)
        let mentionNamesChanged = context.coordinator.updateMentionedSkillNames(mentionedSkillNames)
        let canonicalText = TurnComposerInlineSkillToken.canonicalText(from: uiView.attributedText)
        let shouldApplyBindingText = context.coordinator.shouldApplyBindingText(
            text,
            textViewCanonicalText: canonicalText,
            to: uiView
        )
        let shouldCompareAttributedText = shouldApplyBindingText
            && (canonicalText != text || mentionNamesChanged || fontChanged)
        let nextAttributedText = shouldCompareAttributedText
            ? TurnComposerInlineSkillToken.displayAttributedString(
                canonicalText: text,
                mentionNames: mentionedSkillNames,
                font: nextFont,
                textColor: .label,
                tintColor: skillTintColor
            )
            : nil
        let textChanged = nextAttributedText.map { !uiView.attributedText.isEqual(to: $0) } ?? false
        if let nextAttributedText, textChanged {
            uiView.attributedText = nextAttributedText
            uiView.selectedRange = NSRange(location: uiView.attributedText.length, length: 0)
            context.coordinator.noteAppliedBindingText(text)
        }
        let shouldDeferEditabilityLock = !isEditable && uiView.isEditable && uiView.isFirstResponder
        if !shouldDeferEditabilityLock {
            uiView.isEditable = isEditable
        }
        uiView.isSelectable = true
        if fontChanged {
            uiView.font = nextFont
        }
        uiView.typingAttributes[.font] = nextFont
        uiView.typingAttributes[.foregroundColor] = UIColor.label
        uiView.adjustsFontForContentSizeCategory = true
        uiView.textContainerInset = Self.textContainerInset
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
        if shouldDeferEditabilityLock {
            DispatchQueue.main.async { [weak uiView] in
                uiView?.isEditable = false
            }
        }
        context.coordinator.updateHeightIfNeeded(
            for: uiView,
            force: textChanged || fontChanged || expandedAfterCollapse || maxVisibleLinesChanged
        )
        if expandedAfterCollapse || maxVisibleLinesChanged {
            context.coordinator.scheduleDeferredHeightUpdate(for: uiView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isFocused: $isFocused,
            dynamicHeight: $dynamicHeight,
            minVisibleLines: minVisibleLines,
            maxVisibleLines: maxVisibleLines,
            isCollapsed: isCollapsed,
            mentionedSkillNames: mentionedSkillNames
        )
    }

    // Keeps the composer aligned with the app's normal body sizing instead of
    // the smaller ad hoc size that made the input feel visually detached.
    private func composerUIFont() -> UIFont {
        // Read the SwiftUI environment so UIKit gets refreshed when Dynamic Type changes.
        let _ = dynamicTypeSize
        return AppFont.bodyUIFont()
    }

    private var skillTintColor: UIColor {
        let selectedColor = UserBubbleColor(rawValue: userBubbleColorRawValue) ?? .default
        return selectedColor == .default ? .systemBlue : selectedColor.uiColor
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private var text: Binding<String>
        private var isFocused: Binding<Bool>
        private var dynamicHeight: Binding<CGFloat>
        private let minVisibleLines: CGFloat
        private var lastFocusBindingValue: Bool
        private var pendingHeightValue: CGFloat?
        private var isHeightCommitScheduled = false
        private var lastHeightMeasurementSignature: HeightMeasurementSignature?
        private var lastIsEditable: Bool
        private var lastIsCollapsed: Bool
        private var maxVisibleLines: CGFloat
        private var pendingUIKitText: String?
        private var staleBindingTextDuringPendingEdit: String?
        private var mentionedSkillNames: [String]

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            dynamicHeight: Binding<CGFloat>,
            minVisibleLines: CGFloat,
            maxVisibleLines: CGFloat,
            isCollapsed: Bool,
            mentionedSkillNames: [String]
        ) {
            self.text = text
            self.isFocused = isFocused
            self.dynamicHeight = dynamicHeight
            self.minVisibleLines = minVisibleLines
            self.maxVisibleLines = maxVisibleLines
            // A freshly created text view is never first responder, so start
            // from `false` regardless of the binding: when the collapsed
            // composer sets focus *before* mounting this view, the first
            // `syncFocusIfNeeded` must see a change and raise the keyboard.
            self.lastFocusBindingValue = false
            self.lastIsEditable = true
            self.lastIsCollapsed = isCollapsed
            self.mentionedSkillNames = mentionedSkillNames
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

        fileprivate func noteCollapsedState(_ isCollapsed: Bool) -> Bool {
            let expandedAfterCollapse = lastIsCollapsed && !isCollapsed
            lastIsCollapsed = isCollapsed
            return expandedAfterCollapse
        }

        fileprivate func updateMaxVisibleLines(_ value: CGFloat) -> Bool {
            guard abs(maxVisibleLines - value) > 0.1 else {
                return false
            }
            maxVisibleLines = value
            lastHeightMeasurementSignature = nil
            return true
        }

        fileprivate func updateMentionedSkillNames(_ names: [String]) -> Bool {
            guard mentionedSkillNames != names else { return false }
            mentionedSkillNames = names
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            // Let heavier streaming rows back off briefly so keystrokes stay responsive
            // while a run is repainting tool/status activity.
            StreamingUIInteractionMonitor.noteComposerKeystroke()
            TurnComposerInlineSkillToken.normalizeTokenAttributes(in: textView.textStorage)
            let newText = TurnComposerInlineSkillToken.canonicalText(from: textView.attributedText)
            if text.wrappedValue != newText {
                pendingUIKitText = newText
                staleBindingTextDuringPendingEdit = text.wrappedValue
                let targetText = text
                // Defer the binding write out of UIKit's edit transaction to avoid
                // AttributeGraph cycles.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard self.pendingUIKitText == newText else { return }
                    if targetText.wrappedValue != newText {
                        targetText.wrappedValue = newText
                    }
                    self.pendingUIKitText = nil
                    self.staleBindingTextDuringPendingEdit = nil
                }
            }
            updateHeightIfNeeded(for: textView, force: true)
        }

        // Prevents SwiftUI re-renders from writing an older binding value over
        // fresh UIKit edits while the deferred binding update is still queued.
        fileprivate func shouldApplyBindingText(
            _ bindingText: String,
            textViewCanonicalText: String,
            to textView: UITextView
        ) -> Bool {
            if hasActiveMarkedText(in: textView) {
                return shouldApplyBindingTextDuringPendingEdit(
                    bindingText,
                    textViewText: textViewCanonicalText
                )
            }

            guard
                textView.isFirstResponder,
                let pendingUIKitText,
                textViewCanonicalText == pendingUIKitText
            else {
                return true
            }

            return shouldApplyBindingTextDuringPendingEdit(bindingText, textViewText: pendingUIKitText)
        }

        fileprivate func noteAppliedBindingText(_ bindingText: String) {
            guard pendingUIKitText != nil else { return }
            if bindingText != pendingUIKitText || bindingText == staleBindingTextDuringPendingEdit {
                pendingUIKitText = nil
                staleBindingTextDuringPendingEdit = nil
            }
        }

        // Allows explicit external updates, such as Send clearing the composer,
        // while still ignoring SwiftUI's stale echo of the previous binding.
        private func shouldApplyBindingTextDuringPendingEdit(_ bindingText: String, textViewText: String) -> Bool {
            guard let pendingUIKitText else {
                return bindingText == textViewText
            }

            if bindingText == pendingUIKitText {
                return true
            }
            if bindingText == staleBindingTextDuringPendingEdit {
                return false
            }

            self.pendingUIKitText = nil
            self.staleBindingTextDuringPendingEdit = nil
            return true
        }

        // iOS keeps predictive/autocorrect composition in marked text; external
        // writes during that window can duplicate characters or move the caret.
        private func hasActiveMarkedText(in textView: UITextView) -> Bool {
            guard let markedRange = textView.markedTextRange else {
                return false
            }
            return !markedRange.isEmpty
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            let sanitized = replacement.replacingOccurrences(of: "\u{FFFC}", with: "")
            let expanded = TurnComposerInlineSkillToken.expandedEditingRange(
                for: range,
                in: textView.attributedText
            )
            guard expanded != range || sanitized != replacement else { return true }

            textView.textStorage.beginEditing()
            textView.textStorage.replaceCharacters(in: expanded, with: sanitized)
            if !sanitized.isEmpty {
                textView.textStorage.setAttributes(
                    baseTypingAttributes(for: textView),
                    range: NSRange(location: expanded.location, length: (sanitized as NSString).length)
                )
            }
            textView.textStorage.endEditing()
            textView.selectedRange = NSRange(
                location: expanded.location + (sanitized as NSString).length,
                length: 0
            )
            textView.typingAttributes = baseTypingAttributes(for: textView)
            textViewDidChange(textView)
            return false
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let snapped = TurnComposerInlineSkillToken.snappedSelection(
                textView.selectedRange,
                in: textView.attributedText
            )
            if snapped != textView.selectedRange {
                textView.selectedRange = snapped
            }
            textView.typingAttributes = baseTypingAttributes(for: textView)
        }

        private func baseTypingAttributes(for textView: UITextView) -> [NSAttributedString.Key: Any] {
            [
                .font: textView.font ?? AppFont.bodyUIFont(),
                .foregroundColor: UIColor.label,
            ]
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            // UIKit can send focus callbacks while SwiftUI is updating the representable.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isFocused.wrappedValue else { return }
                self.isFocused.wrappedValue = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            // Defer binding writes out of UIKit's edit transaction to avoid AttributeGraph cycles.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isFocused.wrappedValue else { return }
                self.isFocused.wrappedValue = false
            }
        }

        fileprivate func updateHeightIfNeeded(for textView: UITextView, force: Bool = false) {
            let signature = heightMeasurementSignature(for: textView)
            guard force || signature != lastHeightMeasurementSignature else {
                return
            }
            lastHeightMeasurementSignature = signature
            updateHeight(for: textView)
        }

        // The collapsed capsule can receive an external transcript before
        // SwiftUI has laid out the expanded composer frame. Measure once more
        // after layout so the full transcript, not the old one-line box, drives height.
        fileprivate func scheduleDeferredHeightUpdate(for textView: UITextView) {
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                textView.layoutIfNeeded()
                self.updateHeightIfNeeded(for: textView, force: true)
            }
        }

        private func updateHeight(for textView: UITextView) {
            textView.layoutIfNeeded()
            if let textLayoutManager = textView.textLayoutManager {
                textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
            }
            let lineHeight = (textView.font ?? AppFont.bodyUIFont()).lineHeight
            let verticalInset = textView.textContainerInset.top + textView.textContainerInset.bottom
            let minHeight = ceil(lineHeight * minVisibleLines + verticalInset)
            let maxHeight = ceil(lineHeight * maxVisibleLines + verticalInset)
            let targetWidth = max(textView.bounds.width, textView.textContainer.size.width, 1)
            let fitSize = CGSize(width: targetWidth, height: .greatestFiniteMagnitude)
            var measured = ceil(textView.sizeThatFits(fitSize).height)
            let shouldScroll = measured > maxHeight
            if textView.isScrollEnabled != shouldScroll {
                textView.isScrollEnabled = shouldScroll
                textView.alwaysBounceVertical = shouldScroll
                textView.showsVerticalScrollIndicator = shouldScroll
                textView.invalidateIntrinsicContentSize()
                measured = ceil(textView.sizeThatFits(fitSize).height)
            }
            let clamped = min(max(measured, minHeight), maxHeight)
            normalizeViewport(in: textView, shouldScroll: shouldScroll)

            if abs(dynamicHeight.wrappedValue - clamped) > 0.5 {
                scheduleHeightCommit(clamped)
            }

            keepCaretVisible(in: textView)
        }

        // Avoids recalculating UITextView layout when only the streaming transcript invalidated SwiftUI.
        private func heightMeasurementSignature(for textView: UITextView) -> HeightMeasurementSignature {
            let font = textView.font ?? AppFont.bodyUIFont()
            let width = max(textView.bounds.width, textView.textContainer.size.width, 1)
            let verticalInset = textView.textContainerInset.top + textView.textContainerInset.bottom
            return HeightMeasurementSignature(
                textHash: textView.text.hashValue,
                widthBucket: Int((width * 2).rounded()),
                lineHeightBucket: Int((font.lineHeight * 10).rounded()),
                verticalInsetBucket: Int((verticalInset * 10).rounded()),
                isScrollEnabled: textView.isScrollEnabled
            )
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
            let editabilityDidChange = isEditable != lastIsEditable
            lastFocusBindingValue = shouldBeFocused
            lastIsEditable = isEditable

            // Only drive focus changes when the binding or editability actually flipped.
            // Reacting on every updateUIView when the value is merely "still true"
            // causes a becomeFirstResponder → didBeginEditing → binding write →
            // updateUIView → becomeFirstResponder loop that drops the keyboard.
            guard focusBindingDidChange || editabilityDidChange else { return }

            if shouldBeFocused && isEditable {
                guard !textView.isFirstResponder else { return }
                // Focus synchronously when the view is already attached so the
                // keyboard starts rising in the same frame as the tap; a view
                // that is still mounting has no window yet and must defer one
                // runloop turn until it's in the hierarchy.
                if textView.window != nil {
                    textView.becomeFirstResponder()
                } else {
                    DispatchQueue.main.async {
                        textView.becomeFirstResponder()
                    }
                }
            } else if !shouldBeFocused || !isEditable {
                guard textView.isFirstResponder else { return }
                // Resign in the same update that flips the SwiftUI focus binding.
                // Deferring this by one run-loop turn lets the composer begin its
                // collapse while the keyboard still owns the bottom safe area,
                // producing a second layout correction when UIKit catches up.
                textView.resignFirstResponder()
            }
        }
    }

    private struct HeightMeasurementSignature: Equatable {
        let textHash: Int
        let widthBucket: Int
        let lineHeightBucket: Int
        let verticalInsetBucket: Int
        let isScrollEnabled: Bool
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
