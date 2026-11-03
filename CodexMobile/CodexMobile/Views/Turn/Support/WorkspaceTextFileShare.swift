// FILE: WorkspaceTextFileShare.swift
// Purpose: Exports a previewed text file as a named attachment in the iOS share sheet.
// Layer: Turn UI support
// Exports: WorkspaceTextFileShare, WorkspaceTextFileShareSheet
// Depends on: Foundation, SwiftUI, UIKit

import Foundation
import SwiftUI
import UIKit

struct WorkspaceTextFileShare {
    let fileURL: URL
    private let directoryURL: URL

    init(fileName: String, content: String) throws {
        let name = (fileName as NSString).lastPathComponent
        let safeName = name.isEmpty || name == "." || name == ".." ? "document.txt" : name
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Remodex-Share-\(UUID().uuidString)", isDirectory: true)
        let destination = directory.appendingPathComponent(safeName, isDirectory: false)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try content.write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        directoryURL = directory
        fileURL = destination
    }

    // Keep the attachment available until the system share sheet has finished using it.
    func removeTemporaryFile() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

struct WorkspaceTextFileShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
