// FILE: TurnImagePreview.swift
// Purpose: Reusable fullscreen image preview with zoom, share, and save actions for timeline media.
// Layer: View Support
// Exports: PreviewImagePayload, ZoomableImagePreviewScreen, ImageSaveCoordinator
// Depends on: SwiftUI, UIKit

import SwiftUI
import UIKit

struct PreviewImagePayload: Identifiable {
    let id: String
    let image: UIImage
    var title: String? = nil

    init(id: String = UUID().uuidString, image: UIImage, title: String? = nil) {
        self.id = id
        self.image = image
        self.title = title
    }
}

struct ZoomableImagePreviewScreen: View {
    let payload: PreviewImagePayload
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingShareSheet = false
    @State private var alertMessage: String?
    @State private var saveCoordinator = ImageSaveCoordinator()

    var body: some View {
        ZStack(alignment: .top) {
            previewBackground
                .ignoresSafeArea()
                .allowsHitTesting(false)

            ZoomableImageScrollView(image: payload.image)
                .ignoresSafeArea()

            topBar
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .zIndex(2)
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: $isShowingShareSheet) {
            ActivityViewController(items: [payload.image])
        }
        .alert("Image", isPresented: alertIsPresented, actions: {
            Button("OK", role: .cancel) {
                alertMessage = nil
            }
        }, message: {
            Text(alertMessage ?? "")
        })
    }

    private var previewBackground: some View {
        ZStack {
            Color(.systemBackground)

            LinearGradient(
                colors: [
                    Color(.secondarySystemBackground).opacity(colorScheme == .dark ? 0.82 : 0.65),
                    Color(.systemBackground)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    Color.accentColor.opacity(colorScheme == .dark ? 0.14 : 0.08),
                    .clear
                ],
                center: .center,
                startRadius: 80,
                endRadius: 520
            )
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            themedCircleButton(systemName: "xmark") {
                onDismiss()
            }

            if let title = payload.title, !title.isEmpty {
                Text(title)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .adaptiveGlass(.regular, in: Capsule())
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                themedCircleButton(systemName: "square.and.arrow.up") {
                    isShowingShareSheet = true
                }

                themedCircleButton(systemName: "square.and.arrow.down") {
                    saveCoordinator.save(payload.image) { result in
                        switch result {
                        case .success:
                            alertMessage = "Saved to Photos."
                        case .failure(let error):
                            alertMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }

    private func themedCircleButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            action()
        } label: {
            Image(systemName: systemName)
                .font(AppFont.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .adaptiveGlass(.regular, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var alertIsPresented: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    alertMessage = nil
                }
            }
        )
    }
}

private struct ZoomableImageScrollView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.zoomScale = 1
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear

        let imageView = context.coordinator.imageView
        imageView.contentMode = .scaleAspectFit
        imageView.image = image
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        scrollView.addSubview(imageView)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView.image = image
        context.coordinator.imageView.frame = scrollView.bounds
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }
    }
}

private struct ActivityViewController: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

final class ImageSaveCoordinator: NSObject {
    private var completion: ((Result<Void, Error>) -> Void)?

    func save(_ image: UIImage, completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion
        UIImageWriteToSavedPhotosAlbum(
            image,
            self,
            #selector(image(_:didFinishSavingWithError:contextInfo:)),
            nil
        )
    }

    @objc
    private func image(
        _ image: UIImage,
        didFinishSavingWithError error: Error?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        if let error {
            completion?(.failure(error))
        } else {
            completion?(.success(()))
        }
        completion = nil
    }
}
