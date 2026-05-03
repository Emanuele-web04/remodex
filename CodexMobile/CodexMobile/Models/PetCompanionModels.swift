// FILE: PetCompanionModels.swift
// Purpose: Models Codex-compatible companion pets and their sprite atlas layout.
// Layer: Model
// Exports: PetCompanion, PetCompanionPhase, PetCompanionPosition, PetCompanionLayout
// Depends on: Foundation, CoreGraphics

import CoreGraphics
import Foundation

struct PetCompanion: Identifiable, Equatable, Sendable {
    let id: String
    let folderName: String
    let displayName: String
    let description: String?
    let spritesheetDataURL: String?
    let spritesheetMimeType: String?
    let spritesheetByteLength: Int?
}

struct PetCompanionStatusSnapshot: Equatable, Sendable {
    let phase: PetCompanionPhase
    var title: String?
    var detail: String?

    static let idle = PetCompanionStatusSnapshot(phase: .idle)

    var showsLabel: Bool {
        title != nil || detail != nil
    }
}

enum PetCompanionPhase: String, CaseIterable, Sendable {
    case idle
    case runningRight = "running-right"
    case runningLeft = "running-left"
    case waving
    case jumping
    case failed
    case waiting
    case running
    case review

    static let cellSize = CGSize(width: 192, height: 208)
    static let atlasColumns = 8

    var rowIndex: Int {
        switch self {
        case .idle: 0
        case .runningRight: 1
        case .runningLeft: 2
        case .waving: 3
        case .jumping: 4
        case .failed: 5
        case .waiting: 6
        case .running: 7
        case .review: 8
        }
    }

    var frameCount: Int {
        switch self {
        case .idle: 6
        case .runningRight, .runningLeft, .failed: 8
        case .waving: 4
        case .jumping: 5
        case .waiting, .running, .review: 6
        }
    }

    var frameDurationsMilliseconds: [UInt64] {
        switch self {
        case .idle:
            [280, 110, 110, 140, 140, 320]
        case .runningRight, .runningLeft:
            [120, 120, 120, 120, 120, 120, 120, 220]
        case .waving:
            [140, 140, 140, 280]
        case .jumping:
            [140, 140, 140, 140, 280]
        case .failed:
            [140, 140, 140, 140, 140, 140, 140, 240]
        case .waiting:
            [150, 150, 150, 150, 150, 260]
        case .running:
            [120, 120, 120, 120, 120, 220]
        case .review:
            [150, 150, 150, 150, 150, 280]
        }
    }

    var slowFrameDurationsMilliseconds: [UInt64] {
        frameDurationsMilliseconds.map { $0 * 6 }
    }
}

struct PetCompanionPosition: Codable, Equatable, Sendable {
    var normalizedX: Double
    var normalizedY: Double

    static let `default` = PetCompanionPosition(normalizedX: 0.82, normalizedY: 0.72)
}

enum PetCompanionLayout {
    static func point(
        for position: PetCompanionPosition,
        in containerSize: CGSize,
        petSize: CGSize,
        leftExclusionWidth: CGFloat,
        bottomExclusionHeight: CGFloat
    ) -> CGPoint {
        let rawPoint = CGPoint(
            x: containerSize.width * CGFloat(position.normalizedX),
            y: containerSize.height * CGFloat(position.normalizedY)
        )

        return clampedPoint(
            rawPoint,
            in: containerSize,
            petSize: petSize,
            leftExclusionWidth: leftExclusionWidth,
            bottomExclusionHeight: bottomExclusionHeight
        )
    }

    static func normalizedPosition(
        for point: CGPoint,
        in containerSize: CGSize,
        petSize: CGSize,
        leftExclusionWidth: CGFloat,
        bottomExclusionHeight: CGFloat
    ) -> PetCompanionPosition {
        let clamped = clampedPoint(
            point,
            in: containerSize,
            petSize: petSize,
            leftExclusionWidth: leftExclusionWidth,
            bottomExclusionHeight: bottomExclusionHeight
        )

        guard containerSize.width > 0, containerSize.height > 0 else {
            return .default
        }

        return PetCompanionPosition(
            normalizedX: Double(clamped.x / containerSize.width),
            normalizedY: Double(clamped.y / containerSize.height)
        )
    }

    static func clampedPoint(
        _ point: CGPoint,
        in containerSize: CGSize,
        petSize: CGSize,
        leftExclusionWidth: CGFloat,
        bottomExclusionHeight: CGFloat
    ) -> CGPoint {
        guard containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }

        let horizontalMargin = max(12, petSize.width / 2)
        let verticalMargin = max(12, petSize.height / 2)
        let minX = min(containerSize.width - horizontalMargin, leftExclusionWidth + horizontalMargin)
        let maxX = max(minX, containerSize.width - horizontalMargin)
        let minY = verticalMargin
        let maxY = max(minY, containerSize.height - bottomExclusionHeight - verticalMargin)

        return CGPoint(
            x: min(max(point.x, minX), maxX),
            y: min(max(point.y, minY), maxY)
        )
    }
}
