// FILE: VoiceTranscriptionBackgroundTask.swift
// Purpose: Wraps voice transcription uploads in a cancellable best-effort background task.
// Layer: View Support
// Exports: VoiceTranscriptionBackgroundTask
// Depends on: UIKit

import UIKit

private final class VoiceBackgroundTaskIdentifierBox: @unchecked Sendable {
    var taskID: UIBackgroundTaskIdentifier = .invalid
    var cancelOperation: (() -> Void)?
}

enum VoiceTranscriptionBackgroundTask {
    // Requests a short iOS background window, but callers still own cancellation policy.
    @MainActor
    static func run<T>(
        named name: String = "Remodex voice transcription",
        operation: @escaping () async throws -> T
    ) async throws -> T {
        let operationTask = Task { @MainActor in
            try await operation()
        }
        let taskBox = VoiceBackgroundTaskIdentifierBox()
        taskBox.cancelOperation = {
            operationTask.cancel()
        }

        let taskID = UIApplication.shared.beginBackgroundTask(withName: name) { [taskBox] in
            let expiredTaskID = taskBox.taskID
            guard expiredTaskID != .invalid else {
                return
            }

            // iOS requires the background task to end inside the expiration handler.
            taskBox.cancelOperation?()
            UIApplication.shared.endBackgroundTask(expiredTaskID)
            taskBox.taskID = .invalid
        }

        if taskID != .invalid {
            taskBox.taskID = taskID
        }

        defer {
            operationTask.cancel()
            let currentTaskID = taskBox.taskID
            if currentTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(currentTaskID)
                taskBox.taskID = .invalid
            }
        }

        return try await withTaskCancellationHandler {
            try await operationTask.value
        } onCancel: {
            operationTask.cancel()
        }
    }
}
