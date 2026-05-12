// FILE: TurnViewLifecycleModifier.swift
// Purpose: Groups TurnView lifecycle hooks and change observers so the screen body stays compact.
// Layer: View Modifier
// Exports: turnViewLifecycle
// Depends on: SwiftUI, PhotosUI

import SwiftUI
import PhotosUI

private struct TurnViewLifecycleModifier: ViewModifier {
    let taskID: String
    let activeTurnID: String?
    let isThreadRunning: Bool
    let isConnected: Bool
    let scenePhase: ScenePhase
    let approvalRequestChangeToken: String?
    let photoPickerItems: [PhotosPickerItem]

    let onTask: @Sendable () async -> Void
    let onInitialAppear: () -> Void
    let onPhotoPickerItemsChanged: ([PhotosPickerItem]) -> Void
    let onActiveTurnChanged: (String?) -> Void
    let onThreadRunningChanged: (Bool, Bool) -> Void
    let onConnectionChanged: (Bool, Bool) -> Void
    let onScenePhaseChanged: (ScenePhase) -> Void
    let onApprovalRequestChanged: () -> Void

    func body(content: Content) -> some View {
        content
            .task(id: taskID) {
                await onTask()
            }
            .onAppear(perform: onInitialAppear)
            .onChange(of: photoPickerItems) { _, newItems in
                onPhotoPickerItemsChanged(newItems)
            }
            .onChange(of: activeTurnID) { _, newValue in
                onActiveTurnChanged(newValue)
            }
            .onChange(of: isThreadRunning) { wasRunning, isRunning in
                onThreadRunningChanged(wasRunning, isRunning)
            }
            .onChange(of: isConnected) { wasConnected, isConnected in
                onConnectionChanged(wasConnected, isConnected)
            }
            .onChange(of: scenePhase) { _, newPhase in
                onScenePhaseChanged(newPhase)
            }
            .onChange(of: approvalRequestChangeToken) { _, _ in
                onApprovalRequestChanged()
            }
    }
}

extension View {
    func turnViewLifecycle(
        taskID: String,
        activeTurnID: String?,
        isThreadRunning: Bool,
        isConnected: Bool,
        scenePhase: ScenePhase,
        approvalRequestChangeToken: String?,
        photoPickerItems: [PhotosPickerItem],
        onTask: @escaping @Sendable () async -> Void,
        onInitialAppear: @escaping () -> Void,
        onPhotoPickerItemsChanged: @escaping ([PhotosPickerItem]) -> Void,
        onActiveTurnChanged: @escaping (String?) -> Void,
        onThreadRunningChanged: @escaping (Bool, Bool) -> Void,
        onConnectionChanged: @escaping (Bool, Bool) -> Void,
        onScenePhaseChanged: @escaping (ScenePhase) -> Void,
        onApprovalRequestChanged: @escaping () -> Void
    ) -> some View {
        modifier(
            TurnViewLifecycleModifier(
                taskID: taskID,
                activeTurnID: activeTurnID,
                isThreadRunning: isThreadRunning,
                isConnected: isConnected,
                scenePhase: scenePhase,
                approvalRequestChangeToken: approvalRequestChangeToken,
                photoPickerItems: photoPickerItems,
                onTask: onTask,
                onInitialAppear: onInitialAppear,
                onPhotoPickerItemsChanged: onPhotoPickerItemsChanged,
                onActiveTurnChanged: onActiveTurnChanged,
                onThreadRunningChanged: onThreadRunningChanged,
                onConnectionChanged: onConnectionChanged,
                onScenePhaseChanged: onScenePhaseChanged,
                onApprovalRequestChanged: onApprovalRequestChanged
            )
        )
    }
}
