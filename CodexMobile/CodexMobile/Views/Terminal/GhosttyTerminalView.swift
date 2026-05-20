// FILE: GhosttyTerminalView.swift
// Purpose: UIKit-backed Ghostty renderer that turns bridge SSH output into an interactive iOS terminal.
// Layer: View Infrastructure
// Exports: GhosttyTerminalView
// Depends on: GhosttyKit, UIKit, QuartzCore

import Foundation
import GhosttyKit
import QuartzCore
import UIKit

private enum GhosttyRuntime {
    private static let lock = NSLock()
    private static var initialized = false

    // Ghostty's C runtime must be initialized once before any app/surface is created.
    static func ensureInitialized() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if initialized {
            return true
        }

        let result = ghostty_init(0, nil)
        initialized = result == GHOSTTY_SUCCESS
        return initialized
    }
}

private final class TerminalInputField: UITextField {
    var onDeleteBackward: (() -> Void)?

    override func deleteBackward() {
        onDeleteBackward?()
        super.deleteBackward()
    }
}

private enum TerminalAppearanceScheme: String {
    case light
    case dark

    init(value: String) {
        self = TerminalAppearanceScheme(rawValue: value) ?? .dark
    }

    var ghosttyColorScheme: ghostty_color_scheme_e {
        switch self {
        case .light:
            return GHOSTTY_COLOR_SCHEME_LIGHT
        case .dark:
            return GHOSTTY_COLOR_SCHEME_DARK
        }
    }
}

private extension UIColor {
    convenience init(hexString: String) {
        let sanitized = hexString.replacingOccurrences(of: "#", with: "")
        let value = Int(sanitized, radix: 16) ?? 0
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

private struct TerminalSelectionCell: Equatable {
    let column: Int
    let row: Int
}

private struct TerminalSelectionRange {
    let anchor: TerminalSelectionCell
    let focus: TerminalSelectionCell

    var normalized: (start: TerminalSelectionCell, end: TerminalSelectionCell) {
        if anchor.row < focus.row || (anchor.row == focus.row && anchor.column <= focus.column) {
            return (anchor, focus)
        }
        return (focus, anchor)
    }
}

private struct TerminalSelectionMetrics: Equatable {
    let columns: Int
    let rows: Int
    let cellSize: CGSize
}

private struct TerminalRowCharacter {
    let character: Character
    let startColumn: Int
    let endColumn: Int
}

private struct TerminalVisualRow {
    let text: String
    let hasHardLineBreakAfter: Bool
}

private enum TerminalSelectionHandle {
    case start
    case end
}

private final class TerminalSelectionOverlayView: UIView {
    private static let handleRadius: CGFloat = 7
    private static let handleHitRadius: CGFloat = 30

    private let handlePanGesture = UIPanGestureRecognizer()
    private var activeHandle: TerminalSelectionHandle?

    var onHandleDrag: ((TerminalSelectionHandle, CGPoint, UIGestureRecognizer.State) -> Void)?

    var metrics: TerminalSelectionMetrics? {
        didSet {
            guard oldValue != metrics else { return }
            setNeedsDisplay()
        }
    }

    var selectionRange: TerminalSelectionRange? {
        didSet {
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureHandleGestures()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureHandleGestures()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        handle(at: point) != nil
    }

    override func draw(_ rect: CGRect) {
        guard let metrics, let selectionRange else { return }

        UIColor.systemBlue.withAlphaComponent(0.24).setFill()
        for selectionRect in selectionRects(for: selectionRange, metrics: metrics) {
            UIBezierPath(roundedRect: selectionRect, cornerRadius: 2).fill()
        }

        drawHandles(for: selectionRange, metrics: metrics)
    }

    func menuTargetRect() -> CGRect? {
        guard let metrics, let selectionRange else { return nil }
        let rects = selectionRects(for: selectionRange, metrics: metrics)
        guard var unionRect = rects.first else { return nil }
        for rect in rects.dropFirst() {
            unionRect = unionRect.union(rect)
        }
        return unionRect.insetBy(dx: 0, dy: -6)
    }

    private func configureHandleGestures() {
        isMultipleTouchEnabled = false
        handlePanGesture.addTarget(self, action: #selector(handleHandlePan(_:)))
        addGestureRecognizer(handlePanGesture)
    }

    @objc private func handleHandlePan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            activeHandle = handle(at: location)
            if let activeHandle {
                onHandleDrag?(activeHandle, location, gesture.state)
            }
        case .changed, .ended, .cancelled, .failed:
            guard let activeHandle else { return }
            onHandleDrag?(activeHandle, location, gesture.state)
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                self.activeHandle = nil
            }
        default:
            break
        }
    }

    private func selectionRects(
        for selectionRange: TerminalSelectionRange,
        metrics: TerminalSelectionMetrics
    ) -> [CGRect] {
        let normalizedRange = selectionRange.normalized
        let start = normalizedRange.start
        let end = normalizedRange.end
        guard start.row <= end.row else { return [] }

        let rowRange = start.row...end.row
        return rowRange.compactMap { row in
            let firstColumn = row == start.row ? start.column : 0
            let lastColumn = row == end.row ? end.column : metrics.columns - 1
            guard lastColumn >= firstColumn else { return nil }

            return CGRect(
                x: CGFloat(firstColumn) * metrics.cellSize.width,
                y: CGFloat(row) * metrics.cellSize.height,
                width: CGFloat(lastColumn - firstColumn + 1) * metrics.cellSize.width,
                height: metrics.cellSize.height
            ).insetBy(dx: 0, dy: max(1, metrics.cellSize.height * 0.08))
        }
    }

    private func handle(at point: CGPoint) -> TerminalSelectionHandle? {
        guard let metrics, let selectionRange else { return nil }
        let centers = handleCenters(for: selectionRange, metrics: metrics)
        let startDistance = hypot(point.x - centers.start.x, point.y - centers.start.y)
        let endDistance = hypot(point.x - centers.end.x, point.y - centers.end.y)
        let hitRadius = Self.handleHitRadius

        switch (startDistance <= hitRadius, endDistance <= hitRadius) {
        case (true, true):
            return startDistance <= endDistance ? .start : .end
        case (true, false):
            return .start
        case (false, true):
            return .end
        case (false, false):
            return nil
        }
    }

    private func handleCenters(
        for selectionRange: TerminalSelectionRange,
        metrics: TerminalSelectionMetrics
    ) -> (start: CGPoint, end: CGPoint) {
        let normalizedRange = selectionRange.normalized
        let start = normalizedRange.start
        let end = normalizedRange.end
        let rawCenters = (
            CGPoint(
                x: CGFloat(start.column) * metrics.cellSize.width,
                y: CGFloat(start.row + 1) * metrics.cellSize.height
            ),
            CGPoint(
                x: CGFloat(end.column + 1) * metrics.cellSize.width,
                y: CGFloat(end.row + 1) * metrics.cellSize.height
            )
        )
        return (
            clampHandleCenter(rawCenters.0),
            clampHandleCenter(rawCenters.1)
        )
    }

    private func clampHandleCenter(_ point: CGPoint) -> CGPoint {
        let radius = Self.handleRadius
        guard bounds.width > radius * 2, bounds.height > radius * 2 else { return point }
        return CGPoint(
            x: min(max(point.x, radius), bounds.width - radius),
            y: min(max(point.y, radius), bounds.height - radius)
        )
    }

    private func drawHandles(
        for selectionRange: TerminalSelectionRange,
        metrics: TerminalSelectionMetrics
    ) {
        let radius = Self.handleRadius
        let centers = handleCenters(for: selectionRange, metrics: metrics)

        UIColor.black.withAlphaComponent(0.92).setFill()
        UIBezierPath(
            ovalIn: CGRect(x: centers.start.x - radius, y: centers.start.y - radius, width: radius * 2, height: radius * 2)
        ).fill()
        UIBezierPath(
            ovalIn: CGRect(x: centers.end.x - radius, y: centers.end.y - radius, width: radius * 2, height: radius * 2)
        ).fill()
    }
}

final class GhosttyTerminalView: UIView, UITextFieldDelegate, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
    private static let minimumVerticalScrollStepPoints: CGFloat = 18
    private static let verticalScrollStepMultiplier: CGFloat = 1.15
    private static let selectionDragActivationDistance: CGFloat = 10
    private static let terminalResetSequence = Data("\u{1B}c".utf8)
    private static let terminalReturnSequence = Data([0x0D])

    private let terminalViewport = UIView()
    private let selectionOverlay = TerminalSelectionOverlayView()
    private let inputField = TerminalInputField()
    private let focusTapGesture = UITapGestureRecognizer()
    private let scrollPanGesture = UIPanGestureRecognizer()
    private let selectionLongPressGesture = UILongPressGestureRecognizer()
    private lazy var selectionEditMenuInteraction = UIEditMenuInteraction(delegate: self)
    private var lastViewportSize: CGSize = .zero
    private var lastContentScale: CGFloat = 0
    private var lastReportedGrid: (cols: Int, rows: Int)?
    private var lastAppliedBuffer = Data()
    private var pendingVerticalScrollPoints: CGFloat = 0
    private var isSelectingText = false
    private var selectionAnchorCell: TerminalSelectionCell?
    private var selectionFocusCell: TerminalSelectionCell?
    private var handleDragOppositeCell: TerminalSelectionCell?
    private var handleDragStartCell: TerminalSelectionCell?
    private var handleDragStartLocation: CGPoint?
    private var handleDragTouchOffset: CGPoint?
    private var selectionGestureStartPoint: CGPoint?
    private var selectionGestureDidDrag = false
    private var selectedTextForEditMenu = ""
    private var selectionMenuTargetRect: CGRect?
    private var app: ghostty_app_t?
    private var surface: ghostty_surface_t?
    private var isCreatingSurface = false
    private var surfaceCreationFailed = false
    private var isRendererSuspended = false
    private var appearance = TerminalAppearanceScheme.dark
    private var backgroundColorValue = UIColor(hexString: "#0a0a0a")

    var onInput: ((Data) -> Void)?
    var onResize: ((Int, Int) -> Void)?
    var onNativeAvailabilityChanged: ((Bool) -> Void)?

    var terminalKey: String = "" {
        didSet {
            accessibilityIdentifier = "remodex-terminal-\(terminalKey)"
        }
    }

    var initialBuffer: Data = Data() {
        didSet {
            guard oldValue != initialBuffer else { return }
            applyRemoteBuffer(initialBuffer)
        }
    }

    var fontSize: CGFloat = 10 {
        didSet {
            guard oldValue != fontSize else { return }
            inputField.font = UIFont.monospacedSystemFont(ofSize: max(fontSize, 13), weight: .regular)
            refreshSurface()
        }
    }

    var appearanceScheme: String = TerminalAppearanceScheme.dark.rawValue {
        didSet {
            guard oldValue != appearanceScheme else { return }
            appearance = TerminalAppearanceScheme(value: appearanceScheme)
            refreshSurface()
        }
    }

    var themeConfig: String = "" {
        didSet {
            guard oldValue != themeConfig else { return }
            refreshSurface()
        }
    }

    var backgroundColorHex: String = "#0a0a0a" {
        didSet {
            backgroundColorValue = UIColor(hexString: backgroundColorHex)
            applyTheme()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViewHierarchy()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureViewHierarchy()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        destroySurface()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateContentScale()

        let viewportSize = terminalViewport.bounds.size
        if surface == nil {
            createSurfaceIfPossible()
        }

        guard viewportSize != lastViewportSize || contentScaleFactor != lastContentScale else {
            return
        }

        lastViewportSize = viewportSize
        lastContentScale = contentScaleFactor
        resizeSurface()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateSurfaceRuntimeVisibility()
        guard window != nil else {
            inputField.resignFirstResponder()
            return
        }
        if surface != nil {
            resizeSurface()
        } else {
            setNeedsLayout()
        }
        DispatchQueue.main.async { [weak self] in
            guard self?.canRenderSurface == true else { return }
            self?.requestKeyboardFocus()
        }
    }

    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        if !string.isEmpty {
            emitInput(Self.terminalInputData(for: string))
        }
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        emitInput(Self.terminalReturnSequence)
        textField.text = ""
        return false
    }

    // MARK: - Setup

    private func configureViewHierarchy() {
        applyTheme()
        clipsToBounds = true
        contentScaleFactor = UIScreen.main.scale

        terminalViewport.clipsToBounds = true
        terminalViewport.contentScaleFactor = contentScaleFactor
        terminalViewport.translatesAutoresizingMaskIntoConstraints = false
        terminalViewport.isUserInteractionEnabled = true

        selectionOverlay.translatesAutoresizingMaskIntoConstraints = false
        selectionOverlay.backgroundColor = .clear
        selectionOverlay.isOpaque = false
        selectionOverlay.isUserInteractionEnabled = true
        selectionOverlay.onHandleDrag = { [weak self] handle, location, state in
            self?.handleSelectionHandleDrag(handle, location: location, state: state)
        }

        inputField.delegate = self
        inputField.backgroundColor = .clear
        inputField.textColor = .clear
        inputField.tintColor = .clear
        inputField.font = UIFont.monospacedSystemFont(ofSize: max(fontSize, 13), weight: .regular)
        inputField.autocorrectionType = .no
        inputField.autocapitalizationType = .none
        inputField.spellCheckingType = .no
        inputField.smartDashesType = .no
        inputField.smartQuotesType = .no
        inputField.returnKeyType = .default
        inputField.keyboardType = .asciiCapable
        inputField.enablesReturnKeyAutomatically = false
        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.alpha = 0.02
        inputField.isAccessibilityElement = false
        inputField.accessibilityElementsHidden = true
        inputField.addTarget(self, action: #selector(handleInputEditingDidBegin), for: .editingDidBegin)
        inputField.onDeleteBackward = { [weak self] in
            self?.emitInput(Data([0x7F]))
        }

        focusTapGesture.addTarget(self, action: #selector(handleViewportTap))
        focusTapGesture.require(toFail: selectionLongPressGesture)
        terminalViewport.addGestureRecognizer(focusTapGesture)

        scrollPanGesture.addTarget(self, action: #selector(handleViewportPan(_:)))
        scrollPanGesture.maximumNumberOfTouches = 1
        scrollPanGesture.cancelsTouchesInView = false
        scrollPanGesture.delegate = self
        terminalViewport.addGestureRecognizer(scrollPanGesture)

        selectionLongPressGesture.addTarget(self, action: #selector(handleTextSelectionLongPress(_:)))
        selectionLongPressGesture.minimumPressDuration = 0.35
        selectionLongPressGesture.allowableMovement = 18
        selectionLongPressGesture.cancelsTouchesInView = false
        selectionLongPressGesture.delegate = self
        terminalViewport.addGestureRecognizer(selectionLongPressGesture)
        terminalViewport.addInteraction(selectionEditMenuInteraction)

        addSubview(terminalViewport)
        addSubview(selectionOverlay)
        addSubview(inputField)

        NSLayoutConstraint.activate([
            terminalViewport.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalViewport.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalViewport.topAnchor.constraint(equalTo: topAnchor),
            terminalViewport.bottomAnchor.constraint(equalTo: bottomAnchor),

            selectionOverlay.leadingAnchor.constraint(equalTo: terminalViewport.leadingAnchor),
            selectionOverlay.trailingAnchor.constraint(equalTo: terminalViewport.trailingAnchor),
            selectionOverlay.topAnchor.constraint(equalTo: terminalViewport.topAnchor),
            selectionOverlay.bottomAnchor.constraint(equalTo: terminalViewport.bottomAnchor),

            inputField.trailingAnchor.constraint(equalTo: trailingAnchor),
            inputField.topAnchor.constraint(equalTo: bottomAnchor, constant: 8),
            inputField.widthAnchor.constraint(equalToConstant: 1),
            inputField.heightAnchor.constraint(equalToConstant: 1),
        ])

        registerApplicationLifecycleNotifications()
    }

    private func registerApplicationLifecycleNotifications() {
        isRendererSuspended = UIApplication.shared.applicationState != .active
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleApplicationWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleApplicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleApplicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    // MARK: - App Visibility

    @objc private func handleApplicationWillResignActive() {
        suspendRendererForAppBackground()
    }

    @objc private func handleApplicationDidEnterBackground() {
        suspendRendererForAppBackground()
    }

    @objc private func handleApplicationDidBecomeActive() {
        resumeRendererForActiveApp()
    }

    private var canRenderSurface: Bool {
        window != nil && !isRendererSuspended
    }

    // Tears down Ghostty's IOSurface client before UIKit backgrounds the scene;
    // SSH output keeps accumulating in the Swift snapshot and replays on resume.
    private func suspendRendererForAppBackground() {
        guard !isRendererSuspended else { return }
        isRendererSuspended = true
        inputField.resignFirstResponder()
        tearDownSurfaceForAppBackground()
    }

    private func resumeRendererForActiveApp() {
        guard isRendererSuspended else { return }
        isRendererSuspended = false
        updateSurfaceRuntimeVisibility()
        guard window != nil else { return }
        if surface == nil {
            createSurfaceIfPossible()
        }
        resizeSurface()
        applyRemoteBuffer(initialBuffer)
        requestKeyboardFocus()
    }

    private func tearDownSurfaceForAppBackground() {
        guard surface != nil || app != nil else { return }
        destroySurface()
        lastAppliedBuffer = Data()
        lastViewportSize = .zero
        lastContentScale = 0
    }

    private func updateSurfaceRuntimeVisibility() {
        let isVisible = canRenderSurface
        if let app {
            ghostty_app_set_focus(app, isVisible)
        }
        if let surface {
            ghostty_surface_set_focus(surface, isVisible)
            ghostty_surface_set_occlusion(surface, isVisible)
        }
    }

    // MARK: - Input

    @objc private func handleViewportTap() {
        if hasAppSelection {
            clearAppSelection()
            return
        }
        requestKeyboardFocus()
    }

    // Scroll stays gesture-driven; text selection gets its own long-press path below.
    @objc private func handleViewportPan(_ gesture: UIPanGestureRecognizer) {
        guard let surface else { return }
        guard !isSelectingText else {
            pendingVerticalScrollPoints = 0
            gesture.setTranslation(.zero, in: terminalViewport)
            return
        }

        let location = gesture.location(in: terminalViewport)
        sendGhosttyMousePosition(location)

        switch gesture.state {
        case .began:
            if hasAppSelection {
                clearAppSelection()
            }
            pendingVerticalScrollPoints = 0
            gesture.setTranslation(.zero, in: terminalViewport)
        case .changed:
            let translation = gesture.translation(in: terminalViewport)
            let stepSize = max(fontSize * Self.verticalScrollStepMultiplier, Self.minimumVerticalScrollStepPoints)
            let totalVerticalPoints = pendingVerticalScrollPoints + translation.y
            let verticalSteps = Int(totalVerticalPoints / stepSize)
            pendingVerticalScrollPoints = totalVerticalPoints - (CGFloat(verticalSteps) * stepSize)

            guard verticalSteps != 0 else {
                gesture.setTranslation(.zero, in: terminalViewport)
                return
            }

            ghostty_surface_mouse_scroll(surface, 0, Double(verticalSteps), 0)
            redrawSurface()
            gesture.setTranslation(.zero, in: terminalViewport)
        default:
            pendingVerticalScrollPoints = 0
            gesture.setTranslation(.zero, in: terminalViewport)
        }
    }

    // Long-press selection is iOS-owned: UIKit handles the touch UX while
    // Ghostty remains the source of truth for the text in selected cells.
    @objc private func handleTextSelectionLongPress(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: terminalViewport)
        switch gesture.state {
        case .began:
            clearAppSelection()
            guard let cell = terminalCell(at: location),
                  let initialRange = wordSelectionRange(at: cell) else { return }
            selectionGestureStartPoint = location
            selectionGestureDidDrag = false
            selectedTextForEditMenu = ""
            selectionAnchorCell = initialRange.anchor
            selectionFocusCell = initialRange.focus
            selectionMenuTargetRect = nil
            isSelectingText = true
            updateSelectionOverlay()
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
        case .changed:
            guard isSelectingText else { return }
            guard shouldExtendSelectionDrag(to: location) else { return }
            updateSelectionFocus(at: location)
        case .ended:
            guard isSelectingText else { return }
            if selectionGestureDidDrag {
                updateSelectionFocus(at: location)
            }
            isSelectingText = false
            selectionGestureStartPoint = nil
            selectionGestureDidDrag = false
            presentCopyMenuIfSelectionExists()
        case .cancelled, .failed:
            clearAppSelection()
        default:
            break
        }
    }

    @objc private func handleInputEditingDidBegin() {
        textInputModeDidChange()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard !selectedTextForEditMenu.isEmpty else { return nil }
        let copyAction = UIAction(title: "Copy", image: RemodexIcon.menuUIImage(systemName: "doc.on.doc")) { [weak self] _ in
            self?.copyCurrentSelectionToPasteboard()
        }
        return UIMenu(children: [copyAction])
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        targetRectFor configuration: UIEditMenuConfiguration
    ) -> CGRect {
        selectionMenuTargetRect ?? CGRect(
            x: configuration.sourcePoint.x - 1,
            y: configuration.sourcePoint.y - max(fontSize * 1.4, 18),
            width: 2,
            height: max(fontSize * 1.4, 18)
        )
    }

    private func requestKeyboardFocus() {
        guard window != nil else { return }
        inputField.becomeFirstResponder()
        textInputModeDidChange()
    }

    private func emitInput(_ data: Data) {
        guard !data.isEmpty else { return }
        if hasAppSelection {
            clearAppSelection()
        }
        onInput?(data)
    }

    private func textInputModeDidChange() {
        guard let app else { return }
        ghostty_app_keyboard_changed(app)
    }

    // Terminal apps expect Return as carriage return; raw-mode pickers often ignore LF.
    private static func terminalInputData(for text: String) -> Data {
        text == "\n" || text == "\r" ? terminalReturnSequence : Data(text.utf8)
    }

    private var hasAppSelection: Bool {
        selectionAnchorCell != nil && selectionFocusCell != nil
    }

    private func sendGhosttyMousePosition(_ location: CGPoint) {
        guard let surface else { return }
        ghostty_surface_mouse_pos(
            surface,
            Double(location.x * contentScaleFactor),
            Double(location.y * contentScaleFactor),
            GHOSTTY_MODS_NONE
        )
    }

    // Reads Ghostty text only when the gesture ends, while UIKit owns the
    // mobile selection handles/highlight above the renderer.
    private func presentCopyMenuIfSelectionExists() {
        guard let selectedText = readTextForCurrentSelection(),
              !selectedText.isEmpty else {
            clearAppSelection()
            return
        }

        selectedTextForEditMenu = selectedText
        selectionMenuTargetRect = selectionOverlay.menuTargetRect() ?? terminalViewport.bounds
        let sourcePoint = CGPoint(x: selectionMenuTargetRect?.midX ?? 0, y: selectionMenuTargetRect?.minY ?? 0)
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: sourcePoint)
        selectionEditMenuInteraction.presentEditMenu(with: configuration)
    }

    // Copy uses the captured menu text so live terminal output cannot change
    // what the user selected while the menu is open.
    private func copyCurrentSelectionToPasteboard() {
        let latestSelection = selectedTextForEditMenu.isEmpty
            ? readTextForCurrentSelection() ?? ""
            : selectedTextForEditMenu
        guard !latestSelection.isEmpty else { return }
        UIPasteboard.general.string = latestSelection
        HapticFeedback.shared.triggerImpactFeedback(style: .light)
    }

    private func shouldExtendSelectionDrag(to location: CGPoint) -> Bool {
        guard !selectionGestureDidDrag else { return true }
        guard let selectionGestureStartPoint else { return false }

        let distance = hypot(location.x - selectionGestureStartPoint.x, location.y - selectionGestureStartPoint.y)
        guard distance >= Self.selectionDragActivationDistance else { return false }

        selectionGestureDidDrag = true
        return true
    }

    private func updateSelectionFocus(at location: CGPoint) {
        guard let cell = terminalCell(at: location), cell != selectionFocusCell else { return }
        selectionFocusCell = cell
        selectedTextForEditMenu = ""
        updateSelectionOverlay()
    }

    private func handleSelectionHandleDrag(
        _ handle: TerminalSelectionHandle,
        location: CGPoint,
        state: UIGestureRecognizer.State
    ) {
        guard let currentRange = selectionRange?.normalized else { return }

        if state == .began {
            guard let metrics = currentSelectionMetrics() else { return }
            let startCell = handle == .start ? currentRange.start : currentRange.end
            let startLocation = handleBoundaryPoint(for: startCell, handle: handle, metrics: metrics)
            selectionEditMenuInteraction.dismissMenu()
            handleDragOppositeCell = handle == .start ? currentRange.end : currentRange.start
            handleDragStartCell = startCell
            handleDragStartLocation = startLocation
            handleDragTouchOffset = CGPoint(x: location.x - startLocation.x, y: location.y - startLocation.y)
            return
        }

        if state == .cancelled || state == .failed {
            handleDragOppositeCell = nil
            handleDragStartCell = nil
            handleDragStartLocation = nil
            handleDragTouchOffset = nil
            return
        }

        guard let cell = terminalCellForHandleDrag(at: location) else { return }
        let oppositeCell = handleDragOppositeCell ?? (handle == .start ? currentRange.end : currentRange.start)

        switch handle {
        case .start:
            selectionAnchorCell = cell
            selectionFocusCell = oppositeCell
        case .end:
            selectionAnchorCell = oppositeCell
            selectionFocusCell = cell
        }

        selectedTextForEditMenu = ""
        updateSelectionOverlay()

        if state == .ended {
            handleDragOppositeCell = nil
            handleDragStartCell = nil
            handleDragStartLocation = nil
            handleDragTouchOffset = nil
            presentCopyMenuIfSelectionExists()
        }
    }

    private func updateSelectionOverlay() {
        selectionOverlay.metrics = currentSelectionMetrics()
        if let selectionRange {
            selectionOverlay.selectionRange = selectionRange
            selectionMenuTargetRect = selectionOverlay.menuTargetRect()
        } else {
            selectionOverlay.selectionRange = nil
            selectionMenuTargetRect = nil
        }
    }

    private func clearAppSelection() {
        selectionEditMenuInteraction.dismissMenu()
        isSelectingText = false
        selectionAnchorCell = nil
        selectionFocusCell = nil
        handleDragOppositeCell = nil
        handleDragStartCell = nil
        handleDragStartLocation = nil
        handleDragTouchOffset = nil
        selectionGestureStartPoint = nil
        selectionGestureDidDrag = false
        selectedTextForEditMenu = ""
        selectionMenuTargetRect = nil
        selectionOverlay.selectionRange = nil
    }

    private var selectionRange: TerminalSelectionRange? {
        guard let selectionAnchorCell, let selectionFocusCell else { return nil }
        return TerminalSelectionRange(anchor: selectionAnchorCell, focus: selectionFocusCell)
    }

    private func terminalCell(at location: CGPoint) -> TerminalSelectionCell? {
        guard let metrics = currentSelectionMetrics() else { return nil }
        let clampedX = min(max(location.x, 0), max(terminalViewport.bounds.width - 1, 0))
        let clampedY = min(max(location.y, 0), max(terminalViewport.bounds.height - 1, 0))
        let column = min(max(Int(floor(clampedX / metrics.cellSize.width)), 0), metrics.columns - 1)
        let row = min(max(Int(floor(clampedY / metrics.cellSize.height)), 0), metrics.rows - 1)
        return TerminalSelectionCell(column: column, row: row)
    }

    private func terminalCellForHandleDrag(at location: CGPoint) -> TerminalSelectionCell? {
        guard let metrics = currentSelectionMetrics(),
              let handleDragStartCell,
              let handleDragStartLocation,
              let handleDragTouchOffset else { return nil }

        let effectiveHandleLocation = CGPoint(
            x: location.x - handleDragTouchOffset.x,
            y: location.y - handleDragTouchOffset.y
        )
        let columnDelta = Int(round((effectiveHandleLocation.x - handleDragStartLocation.x) / metrics.cellSize.width))
        let rowDelta = Int(round((effectiveHandleLocation.y - handleDragStartLocation.y) / metrics.cellSize.height))
        return TerminalSelectionCell(
            column: min(max(handleDragStartCell.column + columnDelta, 0), metrics.columns - 1),
            row: min(max(handleDragStartCell.row + rowDelta, 0), metrics.rows - 1)
        )
    }

    private func handleBoundaryPoint(
        for cell: TerminalSelectionCell,
        handle: TerminalSelectionHandle,
        metrics: TerminalSelectionMetrics
    ) -> CGPoint {
        CGPoint(
            x: CGFloat(cell.column + (handle == .end ? 1 : 0)) * metrics.cellSize.width,
            y: CGFloat(cell.row + 1) * metrics.cellSize.height
        )
    }

    private func currentSelectionMetrics() -> TerminalSelectionMetrics? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        guard size.columns > 0,
              size.rows > 0,
              size.cell_width_px > 0,
              size.cell_height_px > 0 else {
            return nil
        }

        return TerminalSelectionMetrics(
            columns: Int(size.columns),
            rows: Int(size.rows),
            cellSize: CGSize(
                width: CGFloat(size.cell_width_px) / contentScaleFactor,
                height: CGFloat(size.cell_height_px) / contentScaleFactor
            )
        )
    }

    private func wordSelectionRange(at cell: TerminalSelectionCell) -> TerminalSelectionRange? {
        guard let metrics = currentSelectionMetrics() else { return nil }
        guard let rowText = visibleTerminalLine(at: cell.row, metrics: metrics) else { return nil }

        let rowCharacters = terminalRowCharacters(for: rowText, maxColumns: metrics.columns)
        guard let selectedIndex = rowCharacters.firstIndex(where: { rowCharacter in
            cell.column >= rowCharacter.startColumn && cell.column < rowCharacter.endColumn
        }) else {
            return nil
        }

        guard isTerminalWordCharacter(rowCharacters[selectedIndex].character) else { return nil }

        var startIndex = selectedIndex
        while startIndex > 0, isTerminalWordCharacter(rowCharacters[startIndex - 1].character) {
            startIndex -= 1
        }

        var endIndex = selectedIndex
        while endIndex + 1 < rowCharacters.count, isTerminalWordCharacter(rowCharacters[endIndex + 1].character) {
            endIndex += 1
        }

        let startColumn = rowCharacters[startIndex].startColumn
        let endColumn = max(rowCharacters[endIndex].endColumn - 1, startColumn)
        return TerminalSelectionRange(
            anchor: TerminalSelectionCell(column: min(startColumn, metrics.columns - 1), row: cell.row),
            focus: TerminalSelectionCell(column: min(endColumn, metrics.columns - 1), row: cell.row)
        )
    }

    private func terminalRowCharacters(for line: String, maxColumns: Int) -> [TerminalRowCharacter] {
        var rowCharacters: [TerminalRowCharacter] = []
        var column = 0

        for character in line {
            let width = terminalDisplayWidth(of: character)
            guard width > 0 else { continue }

            let startColumn = column
            let endColumn = min(column + width, maxColumns)
            guard startColumn < maxColumns, endColumn > startColumn else { break }

            rowCharacters.append(
                TerminalRowCharacter(
                    character: character,
                    startColumn: startColumn,
                    endColumn: endColumn
                )
            )
            column += width
        }

        return rowCharacters
    }

    private func isTerminalWordCharacter(_ character: Character) -> Bool {
        for scalar in character.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar) {
                return false
            }
        }
        return true
    }

    private func terminalDisplayWidth(of character: Character) -> Int {
        var hasVisibleScalar = false
        var hasWideScalar = false

        for scalar in character.unicodeScalars {
            if isZeroWidthTerminalScalar(scalar) || CharacterSet.controlCharacters.contains(scalar) {
                continue
            }

            hasVisibleScalar = true
            if isWideTerminalScalar(scalar) {
                hasWideScalar = true
            }
        }

        guard hasVisibleScalar else { return 0 }
        return hasWideScalar ? 2 : 1
    }

    private func isZeroWidthTerminalScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return CharacterSet.nonBaseCharacters.contains(scalar)
            || value == 0x200C
            || value == 0x200D
            || (0xFE00...0xFE0F).contains(value)
            || (0xE0100...0xE01EF).contains(value)
    }

    private func isWideTerminalScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x1100...0x115F).contains(value)
            || value == 0x2329
            || value == 0x232A
            || (0x2E80...0xA4CF).contains(value)
            || (0xAC00...0xD7A3).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0xFE10...0xFE19).contains(value)
            || (0xFE30...0xFE6F).contains(value)
            || (0xFF00...0xFF60).contains(value)
            || (0xFFE0...0xFFE6).contains(value)
            || (0x1F1E6...0x1F1FF).contains(value)
            || (0x1F300...0x1FAFF).contains(value)
    }

    private func readTextForCurrentSelection() -> String? {
        guard let selectionRange,
              let metrics = currentSelectionMetrics(),
              let rows = visibleTerminalRows(metrics: metrics) else { return nil }
        return selectedText(for: selectionRange, rows: rows, metrics: metrics)
    }

    private func visibleTerminalLine(at row: Int, metrics: TerminalSelectionMetrics) -> String? {
        guard let rows = visibleTerminalRows(metrics: metrics), row >= 0, row < rows.count else { return nil }
        return rows[row].text
    }

    private func selectedText(
        for selectionRange: TerminalSelectionRange,
        rows: [TerminalVisualRow],
        metrics: TerminalSelectionMetrics
    ) -> String {
        let normalizedRange = selectionRange.normalized
        let start = normalizedRange.start
        let end = normalizedRange.end
        guard start.row <= end.row else { return "" }

        let rowRange = Array(start.row...end.row)
        var output = ""
        for (index, row) in rowRange.enumerated() {
            let visualRow = row >= 0 && row < rows.count ? rows[row] : TerminalVisualRow(text: "", hasHardLineBreakAfter: false)
            let firstColumn = row == start.row ? start.column : 0
            let lastColumn = row == end.row ? end.column : metrics.columns - 1
            output += terminalLineText(
                visualRow.text,
                from: firstColumn,
                through: lastColumn,
                maxColumns: metrics.columns,
                includeTrailingBlankCells: row == end.row
            )
            if index < rowRange.count - 1, visualRow.hasHardLineBreakAfter {
                output += "\n"
            }
        }
        return output
    }

    private func terminalLineText(
        _ line: String,
        from firstColumn: Int,
        through lastColumn: Int,
        maxColumns: Int,
        includeTrailingBlankCells: Bool
    ) -> String {
        guard lastColumn >= firstColumn else { return "" }
        let selectedStart = min(max(firstColumn, 0), maxColumns - 1)
        let selectedEnd = min(max(lastColumn, selectedStart), maxColumns - 1)
        let rowCharacters = terminalRowCharacters(for: line, maxColumns: maxColumns)
        var output = ""
        var cursorColumn = selectedStart

        for rowCharacter in rowCharacters where rowCharacter.endColumn > selectedStart && rowCharacter.startColumn <= selectedEnd {
            if rowCharacter.startColumn > cursorColumn {
                output += String(repeating: " ", count: rowCharacter.startColumn - cursorColumn)
            }
            output.append(rowCharacter.character)
            cursorColumn = max(cursorColumn, rowCharacter.endColumn)
        }

        if includeTrailingBlankCells, cursorColumn <= selectedEnd {
            output += String(repeating: " ", count: selectedEnd - cursorColumn + 1)
        }

        return output
    }

    private func visibleTerminalRows(metrics: TerminalSelectionMetrics) -> [TerminalVisualRow]? {
        guard let visibleText = readVisibleTerminalText() else { return nil }
        let hardLines = visibleText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        return visualTerminalRows(from: hardLines, metrics: metrics)
    }

    private func visualTerminalRows(from hardLines: [String], metrics: TerminalSelectionMetrics) -> [TerminalVisualRow] {
        var rows: [TerminalVisualRow] = []

        for (hardLineIndex, hardLine) in hardLines.enumerated() {
            let wrappedRows = wrapTerminalLine(hardLine, maxColumns: metrics.columns)
            for (wrappedRowIndex, wrappedRow) in wrappedRows.enumerated() {
                rows.append(
                    TerminalVisualRow(
                        text: wrappedRow,
                        hasHardLineBreakAfter: hardLineIndex < hardLines.count - 1 && wrappedRowIndex == wrappedRows.count - 1
                    )
                )
            }
            if rows.count >= metrics.rows {
                return Array(rows.prefix(metrics.rows))
            }
        }

        if rows.count < metrics.rows {
            rows.append(
                contentsOf: Array(
                    repeating: TerminalVisualRow(text: "", hasHardLineBreakAfter: false),
                    count: metrics.rows - rows.count
                )
            )
        }
        return rows
    }

    private func wrapTerminalLine(_ line: String, maxColumns: Int) -> [String] {
        guard maxColumns > 0 else { return [line] }
        var rows: [String] = []
        var currentRow = ""
        var currentWidth = 0

        for character in line {
            let width = max(terminalDisplayWidth(of: character), 0)
            if width > 0, currentWidth + width > maxColumns {
                rows.append(currentRow)
                currentRow = ""
                currentWidth = 0
            }
            currentRow.append(character)
            currentWidth += width
        }

        rows.append(currentRow)
        return rows
    }

    private func readVisibleTerminalText() -> String? {
        guard let metrics = currentSelectionMetrics() else { return nil }
        return readText(
            for: TerminalSelectionRange(
                anchor: TerminalSelectionCell(column: 0, row: 0),
                focus: TerminalSelectionCell(column: metrics.columns - 1, row: metrics.rows - 1)
            )
        )
    }

    private func readText(for selectionRange: TerminalSelectionRange) -> String? {
        guard let surface else { return nil }
        let normalizedRange = selectionRange.normalized
        var selection = ghostty_selection_s()
        selection.top_left = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: UInt32(normalizedRange.start.column),
            y: UInt32(normalizedRange.start.row)
        )
        selection.bottom_right = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: UInt32(normalizedRange.end.column),
            y: UInt32(normalizedRange.end.row)
        )
        selection.rectangle = false

        var text = ghostty_text_s(
            tl_px_x: 0,
            tl_px_y: 0,
            offset_start: 0,
            offset_len: 0,
            text: nil,
            text_len: 0
        )

        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return nil }

        let bytes = UnsafeBufferPointer(
            start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
            count: Int(text.text_len)
        )
        return String(decoding: bytes, as: UTF8.self)
    }

    // Clipboard callbacks let Ghostty's own copy/paste actions bridge to the iOS pasteboard.
    private func completeClipboardRead(state: UnsafeMutableRawPointer?) -> Bool {
        guard let surface else { return false }

        let text = readSystemPasteboardString()
        text.withCString { cString in
            ghostty_surface_complete_clipboard_request(surface, cString, state, !text.isEmpty)
        }
        return true
    }

    // Chooses plain text when Ghostty provides multiple clipboard representations.
    private func writeClipboard(contents: UnsafePointer<ghostty_clipboard_content_s>?, count: Int) {
        guard let contents, count > 0 else { return }

        var fallbackText: String?
        for index in 0..<count {
            let item = contents[index]
            guard let data = item.data else { continue }
            let text = String(cString: data)
            let mime = item.mime.map { String(cString: $0) } ?? ""

            if mime == "text/plain" || mime.hasPrefix("text/") {
                writeSystemPasteboardString(text)
                return
            }
            fallbackText = fallbackText ?? text
        }

        if let fallbackText {
            writeSystemPasteboardString(fallbackText)
        }
    }

    private func readSystemPasteboardString() -> String {
        if Thread.isMainThread {
            return UIPasteboard.general.string ?? ""
        }

        var value = ""
        DispatchQueue.main.sync {
            value = UIPasteboard.general.string ?? ""
        }
        return value
    }

    private func writeSystemPasteboardString(_ text: String) {
        if Thread.isMainThread {
            UIPasteboard.general.string = text
        } else {
            DispatchQueue.main.async {
                UIPasteboard.general.string = text
            }
        }
    }

    // MARK: - Ghostty Surface

    private func createSurfaceIfPossible() {
        guard surface == nil, app == nil, !isCreatingSurface, !surfaceCreationFailed else { return }
        guard terminalViewport.bounds.width > 0, terminalViewport.bounds.height > 0 else { return }
        guard canRenderSurface else { return }
        guard GhosttyRuntime.ensureInitialized() else {
            markSurfaceCreationFailed()
            return
        }

        isCreatingSurface = true
        defer { isCreatingSurface = false }

        var runtimeConfig = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { _ in },
            action_cb: { _, _, _ in false },
            read_clipboard_cb: { userdata, _, state in
                guard let userdata else { return false }
                let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
                return view.completeClipboardRead(state: state)
            },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { userdata, _, contents, count, _ in
                guard let userdata else { return }
                let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
                view.writeClipboard(contents: contents, count: count)
            },
            close_surface_cb: { _, _ in }
        )

        guard let config = ghostty_config_new() else {
            markSurfaceCreationFailed()
            return
        }
        loadThemeConfig(into: config)
        ghostty_config_finalize(config)
        defer { ghostty_config_free(config) }

        guard let createdApp = ghostty_app_new(&runtimeConfig, config) else {
            markSurfaceCreationFailed()
            return
        }

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_IOS
        surfaceConfig.platform.ios.uiview = Unmanaged.passUnretained(terminalViewport).toOpaque()
        surfaceConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        surfaceConfig.scale_factor = Double(contentScaleFactor)
        surfaceConfig.font_size = Float(fontSize)
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        surfaceConfig.use_custom_io = true

        guard let createdSurface = ghostty_surface_new(createdApp, &surfaceConfig) else {
            ghostty_app_free(createdApp)
            markSurfaceCreationFailed()
            return
        }

        app = createdApp
        surface = createdSurface
        onNativeAvailabilityChanged?(true)
        ghostty_app_set_color_scheme(createdApp, appearance.ghosttyColorScheme)
        ghostty_surface_set_color_scheme(createdSurface, appearance.ghosttyColorScheme)
        setupWriteCallback()
        updateSurfaceRuntimeVisibility()
        resizeSurface()
        feedBuffer(initialBuffer)
    }

    private func resetSurface() {
        destroySurface()
        lastAppliedBuffer = Data()
        lastViewportSize = .zero
        lastContentScale = 0
        lastReportedGrid = nil
        surfaceCreationFailed = false
        setNeedsLayout()
    }

    private func markSurfaceCreationFailed() {
        surfaceCreationFailed = true
        onNativeAvailabilityChanged?(false)
    }

    private func refreshSurface() {
        resetSurface()
        createSurfaceIfPossible()
    }

    private func destroySurface() {
        clearAppSelection()
        if let surface {
            ghostty_surface_set_write_callback(surface, nil, nil)
            ghostty_surface_free(surface)
        }
        if let app {
            ghostty_app_free(app)
        }
        surface = nil
        app = nil
    }

    private func applyRemoteBuffer(_ buffer: Data) {
        guard canRenderSurface else { return }
        guard surface != nil else {
            createSurfaceIfPossible()
            return
        }

        if Data(buffer.prefix(lastAppliedBuffer.count)) == lastAppliedBuffer {
            let suffix = Data(buffer.dropFirst(lastAppliedBuffer.count))
            feedData(suffix)
            lastAppliedBuffer = buffer
            return
        }

        replaceRenderedBuffer(with: buffer)
    }

    private func feedBuffer(_ buffer: Data) {
        guard canRenderSurface, !buffer.isEmpty else { return }
        feedData(buffer)
        lastAppliedBuffer = buffer
    }

    private func replaceRenderedBuffer(with buffer: Data) {
        guard canRenderSurface else { return }
        guard surface != nil else {
            lastAppliedBuffer = Data()
            createSurfaceIfPossible()
            feedBuffer(buffer)
            return
        }

        feedData(Self.terminalResetSequence)
        lastAppliedBuffer = Data()
        feedBuffer(buffer)
    }

    private func feedData(_ data: Data) {
        guard canRenderSurface, let surface, !data.isEmpty else { return }

        data.withUnsafeBytes { buffer in
            guard let pointer = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            ghostty_surface_feed_data(surface, pointer, buffer.count)
        }

        redrawSurface()
    }

    private func setupWriteCallback() {
        guard let surface else { return }

        let userdata = Unmanaged.passUnretained(self).toOpaque()
        ghostty_surface_set_write_callback(surface, { userdata, data, len in
            guard let userdata, let data, len > 0 else { return }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
            let bytes = Data(bytes: data, count: len)

            DispatchQueue.main.async {
                view.onInput?(bytes)
            }
        }, userdata)
    }

    private func resizeSurface() {
        guard let surface else {
            emitEstimatedResize()
            return
        }

        let scale = contentScaleFactor
        let width = UInt32(max(floor(terminalViewport.bounds.width * scale), 1))
        let height = UInt32(max(floor(terminalViewport.bounds.height * scale), 1))

        terminalViewport.contentScaleFactor = scale
        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
        ghostty_surface_set_size(surface, width, height)
        updateSurfaceRuntimeVisibility()
        guard canRenderSurface else { return }
        configureIOSurfaceLayers()
        redrawSurface()
        emitGhosttyResize()
        updateSelectionOverlay()
    }

    private func redrawSurface() {
        guard let surface else { return }
        guard canRenderSurface else { return }
        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)
        markIOSurfaceLayersForDisplay()
        emitGhosttyResize()
    }

    private func emitGhosttyResize() {
        guard let surface else {
            emitEstimatedResize()
            return
        }

        let size = ghostty_surface_size(surface)
        emitResize(cols: max(1, Int(size.columns)), rows: max(1, Int(size.rows)))
    }

    private func emitEstimatedResize() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let cellWidth = max(fontSize * 0.62, 1)
        let cellHeight = max(fontSize * 1.35, 1)
        emitResize(
            cols: max(20, min(400, Int(bounds.width / cellWidth))),
            rows: max(5, min(200, Int(bounds.height / cellHeight)))
        )
    }

    private func emitResize(cols: Int, rows: Int) {
        guard lastReportedGrid?.cols != cols || lastReportedGrid?.rows != rows else {
            return
        }

        lastReportedGrid = (cols, rows)
        onResize?(cols, rows)
    }

    private func updateContentScale() {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        if contentScaleFactor != scale {
            contentScaleFactor = scale
        }
    }

    private func configureIOSurfaceLayers() {
        let targetBounds = CGRect(origin: .zero, size: terminalViewport.bounds.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        terminalViewport.layer.sublayers?.forEach { sublayer in
            sublayer.frame = targetBounds
            sublayer.contentsScale = contentScaleFactor
        }
        CATransaction.commit()
    }

    private func markIOSurfaceLayersForDisplay() {
        terminalViewport.layer.setNeedsDisplay()
        terminalViewport.layer.sublayers?.forEach { layer in
            layer.setNeedsDisplay()
        }
    }

    private func applyTheme() {
        backgroundColor = backgroundColorValue
        terminalViewport.backgroundColor = backgroundColorValue
    }

    private func loadThemeConfig(into config: ghostty_config_t) {
        guard let path = writeThemeConfigFile() else { return }
        path.withCString { cString in
            ghostty_config_load_file(config, cString)
        }
    }

    private func writeThemeConfigFile() -> String? {
        guard !themeConfig.isEmpty else { return nil }
        let configContents = themeConfig
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remodex-terminal-theme-\(appearance.rawValue).ghostty")

        do {
            if let existing = try? String(contentsOf: url, encoding: .utf8), existing == configContents {
                return url.path
            }

            try configContents.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            return nil
        }
    }
}
