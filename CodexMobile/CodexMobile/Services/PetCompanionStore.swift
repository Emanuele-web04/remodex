// FILE: PetCompanionStore.swift
// Purpose: Persists and loads the optional Codex companion pet state.
// Layer: Service
// Exports: PetCompanionStore, PetCompanionStatusStore
// Depends on: Foundation, Observation, PetCompanion

import Foundation
import Observation

@MainActor
@Observable
final class PetCompanionStore {
    private enum DefaultsKey {
        static let isEnabled = "codex.pet.isEnabled"
        static let selectedID = "codex.pet.selectedID"
        static let positionX = "codex.pet.positionX"
        static let positionY = "codex.pet.positionY"
    }

    private let defaults: UserDefaults

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: DefaultsKey.isEnabled)
        }
    }
    var availablePets: [PetCompanion] = []
    var renderedPet: PetCompanion?
    var selectedPetID: String? {
        didSet {
            defaults.set(selectedPetID, forKey: DefaultsKey.selectedID)
        }
    }
    var position: PetCompanionPosition {
        didSet {
            defaults.set(position.normalizedX, forKey: DefaultsKey.positionX)
            defaults.set(position.normalizedY, forKey: DefaultsKey.positionY)
        }
    }
    var isLoading = false
    var errorMessage: String?
    @ObservationIgnored private var selectedPetLoadID: String?
    @ObservationIgnored private var selectedPetLoadTask: Task<PetCompanion, Error>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: DefaultsKey.isEnabled)
        self.selectedPetID = defaults.string(forKey: DefaultsKey.selectedID)

        if defaults.object(forKey: DefaultsKey.positionX) != nil,
           defaults.object(forKey: DefaultsKey.positionY) != nil {
            self.position = PetCompanionPosition(
                normalizedX: defaults.double(forKey: DefaultsKey.positionX),
                normalizedY: defaults.double(forKey: DefaultsKey.positionY)
            )
        } else {
            self.position = .default
        }
    }

    var selectedPet: PetCompanion? {
        if let selectedPetID,
           let selected = availablePets.first(where: { $0.id == selectedPetID }) {
            return selected
        }

        return availablePets.first
    }

    func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    func selectPet(id: String?) {
        guard selectedPetID != id else {
            return
        }
        selectedPetID = id
        renderedPet = nil
        selectedPetLoadTask?.cancel()
        selectedPetLoadTask = nil
        selectedPetLoadID = nil
    }

    func updatePosition(_ position: PetCompanionPosition) {
        self.position = position
    }

    func loadPetsIfNeeded(codex: CodexService) async {
        guard availablePets.isEmpty else {
            return
        }
        await refreshPets(codex: codex)
    }

    // Loads metadata first; the selected sprite atlas is fetched separately to keep memory low.
    func refreshPets(codex: CodexService) async {
        guard codex.isConnected else {
            errorMessage = "Connect to your Mac to load local pets."
            return
        }
        guard !isLoading else {
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let pets = try await codex.listPets(includeData: false)
            availablePets = pets
            errorMessage = nil
            if let selectedPetID,
               pets.contains(where: { $0.id == selectedPetID }) {
                await loadSelectedPet(codex: codex)
                return
            }
            selectedPetID = pets.first?.id
            renderedPet = nil
            await loadSelectedPet(codex: codex)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Keeps only the currently displayed pet hydrated with spritesheet data.
    func loadSelectedPet(codex: CodexService) async {
        guard codex.isConnected else {
            return
        }
        guard let selectedPet = selectedPet else {
            renderedPet = nil
            return
        }
        if renderedPet?.id == selectedPet.id,
           renderedPet?.spritesheetDataURL?.isEmpty == false {
            return
        }

        let requestedPetID = selectedPet.id
        let loadTask: Task<PetCompanion, Error>
        if selectedPetLoadID == requestedPetID, let existingTask = selectedPetLoadTask {
            loadTask = existingTask
        } else {
            selectedPetLoadTask?.cancel()
            loadTask = Task { @MainActor in
                try await codex.readPet(id: requestedPetID)
            }
            selectedPetLoadID = requestedPetID
            selectedPetLoadTask = loadTask
        }

        defer {
            if selectedPetLoadID == requestedPetID {
                selectedPetLoadID = nil
                selectedPetLoadTask = nil
            }
        }

        do {
            let loadedPet = try await loadTask.value
            guard selectedPetID == nil || selectedPetID == requestedPetID else {
                return
            }
            renderedPet = loadedPet
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard selectedPetID == nil || selectedPetID == requestedPetID else {
                return
            }
            renderedPet = nil
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
@Observable
final class PetCompanionStatusStore {
    var snapshot = PetCompanionStatusSnapshot.idle

    func update(_ snapshot: PetCompanionStatusSnapshot) {
        guard self.snapshot != snapshot else {
            return
        }
        self.snapshot = snapshot
    }

    func reset() {
        update(.idle)
    }
}
