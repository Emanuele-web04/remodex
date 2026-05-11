// FILE: CameraImagePicker.swift
// Purpose: UIViewControllerRepresentable wrapping UIImagePickerController for camera capture.
// Layer: View Component
// Exports: CameraImagePicker

import SwiftUI
import UIKit

struct CameraImagePicker: UIViewControllerRepresentable {
    let onImageCaptured: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImageCaptured: onImageCaptured, dismiss: dismiss)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImageCaptured: (Data) -> Void
        let dismiss: DismissAction

        init(onImageCaptured: @escaping (Data) -> Void, dismiss: DismissAction) {
            self.onImageCaptured = onImageCaptured
            self.dismiss = dismiss
        }

        private static let maxDimension: CGFloat = 1600

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                let resized = Self.downscale(image, maxDimension: Self.maxDimension)
                if let jpegData = resized.jpegData(compressionQuality: 0.8) {
                    onImageCaptured(jpegData)
                }
            }
            dismiss()
        }

        private static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
            let size = image.size
            let longestSide = max(size.width, size.height)
            guard longestSide > maxDimension else { return image }
            let scale = maxDimension / longestSide
            let newSize = CGSize(width: size.width * scale, height: size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            return renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}
