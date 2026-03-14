// FILE: QRScannerView.swift
// Purpose: AVFoundation camera-based QR scanner for relay session pairing.
// Layer: View
// Exports: QRScannerView
// Depends on: SwiftUI, AVFoundation

import AVFoundation
import SwiftUI

struct QRScannerView: View {
    let onScan: (CodexPairingQRPayload) -> Void

    @State private var scannerError: String?
    @State private var bridgeUpdatePrompt: CodexBridgeUpdatePrompt?
    @State private var didCopyBridgeUpdateCommand = false
    @State private var hasCameraPermission = false
    @State private var isCheckingPermission = true

    init(
        initialBridgeUpdatePrompt: CodexBridgeUpdatePrompt? = nil,
        initialHasCameraPermission: Bool = false,
        initialIsCheckingPermission: Bool = true,
        onScan: @escaping (CodexPairingQRPayload) -> Void
    ) {
        self.onScan = onScan
        _bridgeUpdatePrompt = State(initialValue: initialBridgeUpdatePrompt)
        _hasCameraPermission = State(initialValue: initialHasCameraPermission)
        _isCheckingPermission = State(initialValue: initialIsCheckingPermission)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isCheckingPermission {
                ProgressView()
                    .tint(.white)
            } else if let bridgeUpdatePrompt {
                bridgeUpdateView(prompt: bridgeUpdatePrompt)
            } else if hasCameraPermission {
                QRCameraPreview { code, resetScanLock in
                    handleScanResult(code, resetScanLock: resetScanLock)
                }
                .ignoresSafeArea()

                scannerOverlay
            } else {
                cameraPermissionView
            }
        }
        .task {
            await checkCameraPermission()
        }
        .alert("Scan Error", isPresented: Binding(
            get: { scannerError != nil },
            set: { if !$0 { scannerError = nil } }
        )) {
            Button("OK", role: .cancel) { scannerError = nil }
        } message: {
            Text(scannerError ?? "Invalid QR code")
        }
    }

    // Blocks repeated scans when the camera spots a bridge QR from an incompatible npm release.
    private func bridgeUpdateView(prompt: CodexBridgeUpdatePrompt) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                Text(prompt.title)
                    .font(AppFont.title3(weight: .semibold))
                    .foregroundStyle(.white)

                Text(prompt.message)
                    .font(AppFont.body())
                    .foregroundStyle(.white.opacity(0.82))
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("Do these steps on your Mac")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))

                bridgeUpdateStep(number: "1", title: "Update Remodex", detail: prompt.command, showsCopyButton: true)
                bridgeUpdateStep(number: "2", title: "Start it again", detail: "Run remodex up")
                bridgeUpdateStep(number: "3", title: "Make a new QR code", detail: "Use the new QR shown in the terminal")
                bridgeUpdateStep(number: "4", title: "Come back here", detail: "Then scan the new QR code from the iPhone")
            }

            Button("I Updated It") {
                bridgeUpdatePrompt = nil
                didCopyBridgeUpdateCommand = false
            }
            .font(AppFont.body(weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(.black)
            .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private func bridgeUpdateStep(
        number: String,
        title: String,
        detail: String,
        showsCopyButton: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(AppFont.caption2(weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 20, height: 20)
                .background(.white, in: Circle())
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.white)

                Text(detail)
                    .font(showsCopyButton ? AppFont.mono(.caption) : AppFont.caption())
                    .foregroundStyle(.white.opacity(0.82))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )

                if showsCopyButton {
                    Button(didCopyBridgeUpdateCommand ? "Copied" : "Copy Command") {
                        UIPasteboard.general.string = detail
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        withAnimation(.easeInOut(duration: 0.2)) {
                            didCopyBridgeUpdateCommand = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                didCopyBridgeUpdateCommand = false
                            }
                        }
                    }
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(.white)
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var scannerOverlay: some View {
        VStack(spacing: 24) {
            Spacer()

            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.6), lineWidth: 2)
                .frame(width: 250, height: 250)

            Text("Scan QR code from Remodex CLI")
                .font(AppFont.subheadline(weight: .medium))
                .foregroundStyle(.white)

            Spacer()
        }
    }

    private var cameraPermissionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Camera access needed")
                .font(AppFont.title3(weight: .semibold))
                .foregroundStyle(.white)

            Text("Open Settings and allow camera access to scan the pairing QR code.")
                .font(AppFont.subheadline())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func checkCameraPermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            hasCameraPermission = true
        case .notDetermined:
            hasCameraPermission = await AVCaptureDevice.requestAccess(for: .video)
        default:
            hasCameraPermission = false
        }
        isCheckingPermission = false
    }

    private func handleScanResult(_ code: String, resetScanLock: @escaping () -> Void) {
        switch validatePairingQRCode(code) {
        case .success(let payload):
            onScan(payload)
        case .scanError(let message):
            scannerError = message
            resetScanLock()
        case .bridgeUpdateRequired(let prompt):
            didCopyBridgeUpdateCommand = false
            bridgeUpdatePrompt = prompt
            resetScanLock()
        }
    }
}

private extension CodexBridgeUpdatePrompt {
    static let previewScannerMismatch = CodexBridgeUpdatePrompt(
        title: "Update Remodex on your Mac before scanning",
        message: "This QR code was generated by a different Remodex npm version. Update the package on your Mac to the latest release before scanning a new QR code.",
        command: "npm install -g remodex@latest"
    )
}

// MARK: - Preview

#Preview("Bridge Update Required") {
    QRScannerView(
        initialBridgeUpdatePrompt: .previewScannerMismatch,
        initialIsCheckingPermission: false
    ) { _ in }
}

// MARK: - Camera Preview UIViewRepresentable

private struct QRCameraPreview: UIViewRepresentable {
    let onScan: (String, _ resetScanLock: @escaping () -> Void) -> Void

    func makeUIView(context: Context) -> QRCameraUIView {
        let view = QRCameraUIView()
        view.onScan = { [weak view] code in
            onScan(code) {
                view?.resetScanLock()
            }
        }
        return view
    }

    func updateUIView(_ uiView: QRCameraUIView, context: Context) {}
}

private class QRCameraUIView: UIView, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?

    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.phodex.qr-camera")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupCamera()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupCamera()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }

    private func setupCamera() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return
        }

        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        let output = AVCaptureMetadataOutput()
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        self.layer.addSublayer(layer)
        previewLayer = layer

        sessionQueue.async { [weak self] in
            self?.captureSession.startRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasScanned,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let code = object.stringValue else {
            return
        }

        hasScanned = true
        HapticFeedback.shared.triggerImpactFeedback(style: .heavy)
        onScan?(code)
    }

    func resetScanLock() {
        hasScanned = false
    }

    deinit {
        let session = captureSession
        sessionQueue.async {
            session.stopRunning()
        }
    }
}
