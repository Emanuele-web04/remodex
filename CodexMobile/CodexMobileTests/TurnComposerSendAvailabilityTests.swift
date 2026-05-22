// FILE: TurnComposerSendAvailabilityTests.swift
// Purpose: Locks send-button enable/disable truth table after composer refactor.
// Layer: Unit Test
// Exports: TurnComposerSendAvailabilityTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class TurnComposerSendAvailabilityTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testSendDisabledWhenDisconnected() {
        let state = makeState(isConnected: false)
        XCTAssertTrue(state.isSendDisabled)
    }

    func testSendDisabledWhenSendingInFlight() {
        let state = makeState(isSending: true)
        XCTAssertTrue(state.isSendDisabled)
    }

    func testSendEnabledWhenActiveTurnExistsAndPayloadIsValid() {
        let state = makeState(trimmedInput: "queue this")
        XCTAssertFalse(state.isSendDisabled)
    }

    func testSendDisabledWhenInputAndImagesAreEmpty() {
        let state = makeState(trimmedInput: "", hasReadyImages: false)
        XCTAssertTrue(state.isSendDisabled)
    }

    func testSendDisabledWhenAttachmentStateIsBlocking() {
        let state = makeState(hasBlockingAttachmentState: true)
        XCTAssertTrue(state.isSendDisabled)
    }

    func testSendEnabledWhenConnectedAndPayloadIsValid() {
        let textState = makeState(trimmedInput: "Ship it", hasReadyImages: false)
        XCTAssertFalse(textState.isSendDisabled)

        let imageState = makeState(trimmedInput: "", hasReadyImages: true)
        XCTAssertFalse(imageState.isSendDisabled)
    }

    func testSendEnabledWhenReviewSelectionIsPresentWithoutText() {
        let reviewState = makeState(trimmedInput: "", hasReadyImages: false, hasReviewSelection: true)
        XCTAssertFalse(reviewState.isSendDisabled)
    }

    func testSendEnabledWhenSubagentsSelectionIsPresentWithoutText() {
        let subagentsState = makeState(trimmedInput: "", hasReadyImages: false, hasSubagentsSelection: true)
        XCTAssertFalse(subagentsState.isSendDisabled)
    }

    func testSendEnabledWhenOnlyStructuredMentionIsSelected() {
        let skillState = makeState(trimmedInput: "", hasReadyImages: false, hasSkillSelection: true)
        XCTAssertFalse(skillState.isSendDisabled)

        let pluginState = makeState(trimmedInput: "", hasReadyImages: false, hasPluginSelection: true)
        XCTAssertFalse(pluginState.isSendDisabled)
    }

    func testSendDisabledWhileReviewSelectionIsWaitingForTarget() {
        let reviewState = makeState(
            trimmedInput: "follow up",
            hasReadyImages: false,
            hasReviewSelection: false,
            hasPendingReviewSelection: true
        )
        XCTAssertTrue(reviewState.isSendDisabled)
    }

    func testRunningComposerSendButtonContentPredicate() {
        XCTAssertFalse(makeAccessoryState().hasSendableContent(input: ""))
        XCTAssertFalse(makeAccessoryState().hasSendableContent(input: "   "))

        XCTAssertTrue(makeAccessoryState().hasSendableContent(input: "follow up"))
        XCTAssertTrue(makeAccessoryState(hasAttachment: true).hasSendableContent(input: ""))
        XCTAssertTrue(makeAccessoryState(hasSkillSelection: true).hasSendableContent(input: ""))
    }

    func testSendTurnRestoresRawDraftWhenStartTurnFails() async {
        let service = makeService()
        service.isConnected = true

        let viewModel = TurnViewModel()
        let rawInput = "Please update @TurnView.swift"
        let rawMention = TurnComposerMentionedFile(
            fileName: "TurnView.swift",
            path: "Views/Turn/TurnView.swift"
        )
        let attachment = CodexImageAttachment(
            thumbnailBase64JPEG: "thumb",
            payloadDataURL: "data:image/jpeg;base64,AAAA"
        )

        viewModel.input = rawInput
        viewModel.composerMentionedFiles = [rawMention]
        viewModel.composerAttachments = [
            TurnComposerImageAttachment(id: "attachment-1", state: .ready(attachment))
        ]

        viewModel.sendTurn(codex: service, threadID: "thread-send-failure")
        await waitForSendCompletion(viewModel)

        XCTAssertFalse(viewModel.isSending)
        XCTAssertEqual(viewModel.input, rawInput)
        XCTAssertEqual(viewModel.composerMentionedFiles, [rawMention])
        XCTAssertEqual(viewModel.readyComposerAttachments, [attachment])
        XCTAssertEqual(viewModel.composerAttachments.count, 1)
    }

    func testSendNewThreadPreAppendsFirstMessageBeforeOpeningThread() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true

        var recordedMethods: [String] = []
        var openedThreadID: String?
        var openedThreadMessageText: String?
        var didOpenBeforeTurnStart = false
        service.requestTransportOverride = { method, _ in
            recordedMethods.append(method)
            switch method {
            case "thread/start":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("thread-new"),
                            "title": .string(CodexThread.defaultDisplayTitle),
                            "cwd": .string("/tmp/remodex-local"),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "workspace/checkpointCapture":
                return self.workspaceCheckpointResponse(kind: "messageStart")
            case "workspace/checkpointCopy":
                return self.workspaceCheckpointResponse(kind: "turnStart", copied: true)
            case "turn/start":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["turnId": .string("turn-new")]),
                    includeJSONRPC: false
                )
            case "thread/generateTitle":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["title": .string("First message")]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
        }

        let viewModel = TurnViewModel()
        viewModel.input = "First message"

        let didStart = viewModel.sendNewThread(
            codex: service,
            draftThreadID: "draft-thread",
            preferredProjectPath: "/tmp/remodex-local"
        ) { thread in
            openedThreadID = thread.id
            didOpenBeforeTurnStart = !recordedMethods.contains("turn/start")
            openedThreadMessageText = service.messages(for: thread.id).first?.text
        }
        let immediateDraftMessage = service.messages(for: "draft-thread").first
        await waitForSendCompletion(viewModel)

        XCTAssertTrue(didStart)
        XCTAssertEqual(immediateDraftMessage?.text, "First message")
        XCTAssertEqual(immediateDraftMessage?.deliveryState, .pending)
        XCTAssertEqual(openedThreadID, "thread-new")
        XCTAssertTrue(didOpenBeforeTurnStart)
        XCTAssertEqual(openedThreadMessageText, "First message")
        XCTAssertTrue(service.messages(for: "draft-thread").isEmpty)
        XCTAssertEqual(recordedMethods.filter { $0 == "thread/start" }.count, 1)
        XCTAssertEqual(recordedMethods.filter { $0 == "turn/start" }.count, 1)
        XCTAssertEqual(service.messages(for: "thread-new").filter { $0.role == .user }.count, 1)
        XCTAssertEqual(service.messages(for: "thread-new").first?.turnId, "turn-new")
    }

    func testLocalDraftRestoresComposerStateForSameThread() {
        let service = makeService()
        let firstViewModel = TurnViewModel()
        let attachment = CodexImageAttachment(
            thumbnailBase64JPEG: "thumb",
            payloadDataURL: "data:image/jpeg;base64,AAAA"
        )

        firstViewModel.input = "Draft with @TurnView.swift"
        firstViewModel.composerMentionedFiles = [
            TurnComposerMentionedFile(fileName: "TurnView.swift", path: "Views/Turn/TurnView.swift")
        ]
        firstViewModel.composerMentionedSkills = [
            TurnComposerMentionedSkill(name: "check-code", path: "/skills/check-code/SKILL.md", description: "Review")
        ]
        firstViewModel.composerMentionedPlugins = [
            TurnComposerMentionedPlugin(name: "github", path: "plugin://github", displayName: "GitHub")
        ]
        firstViewModel.composerAttachments = [
            TurnComposerImageAttachment(id: "attachment-1", state: .ready(attachment))
        ]
        firstViewModel.isPlanModeArmed = true
        firstViewModel.isSubagentsSelectionArmed = true
        firstViewModel.saveLocalDraft(codex: service, threadID: "thread-draft")

        let secondViewModel = TurnViewModel()
        secondViewModel.restoreSavedLocalDraftIfNeeded(codex: service, threadID: "thread-draft")

        XCTAssertEqual(secondViewModel.input, firstViewModel.input)
        XCTAssertEqual(secondViewModel.composerMentionedFiles, firstViewModel.composerMentionedFiles)
        XCTAssertEqual(secondViewModel.composerMentionedSkills, firstViewModel.composerMentionedSkills)
        XCTAssertEqual(secondViewModel.composerMentionedPlugins, firstViewModel.composerMentionedPlugins)
        XCTAssertEqual(secondViewModel.readyComposerAttachments, [attachment])
        XCTAssertTrue(secondViewModel.isPlanModeArmed)
        XCTAssertTrue(secondViewModel.isSubagentsSelectionArmed)
    }

    func testLocalDraftReflectsRemovedAttachment() {
        let service = makeService()
        let viewModel = TurnViewModel()
        let attachment = CodexImageAttachment(
            thumbnailBase64JPEG: "thumb",
            payloadDataURL: "data:image/jpeg;base64,AAAA"
        )

        viewModel.input = "Keep the text only"
        viewModel.composerAttachments = [
            TurnComposerImageAttachment(id: "attachment-1", state: .ready(attachment))
        ]
        viewModel.saveLocalDraft(codex: service, threadID: "thread-draft-removal")

        viewModel.removeComposerAttachment(id: "attachment-1")
        viewModel.saveLocalDraft(codex: service, threadID: "thread-draft-removal")

        XCTAssertEqual(service.composerDraft(for: "thread-draft-removal")?.input, "Keep the text only")
        XCTAssertEqual(service.composerDraft(for: "thread-draft-removal")?.attachments, [])
    }

    func testLocalDraftClearsAfterSuccessfulSend() async {
        let service = makeService()
        service.isConnected = true
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "turn/start")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-sent")]),
                includeJSONRPC: false
            )
        }

        let viewModel = TurnViewModel()
        viewModel.input = "Send this"
        viewModel.saveLocalDraft(codex: service, threadID: "thread-draft-clear")

        viewModel.sendTurn(codex: service, threadID: "thread-draft-clear")
        await waitForSendCompletion(viewModel)

        XCTAssertNil(service.composerDraft(for: "thread-draft-clear"))
    }

    func testLocalDraftSurvivesFailedSend() async {
        let service = makeService()
        service.isConnected = true

        let viewModel = TurnViewModel()
        viewModel.input = "Retry this later"
        viewModel.saveLocalDraft(codex: service, threadID: "thread-draft-failure")

        viewModel.sendTurn(codex: service, threadID: "thread-draft-failure")
        await waitForSendCompletion(viewModel)

        XCTAssertEqual(service.composerDraft(for: "thread-draft-failure")?.input, "Retry this later")
        XCTAssertEqual(viewModel.input, "Retry this later")
    }

    func testSendTurnUsesCannedPromptWhenSubagentsChipIsSelected() async {
        let service = makeService()
        service.isConnected = true

        var capturedParams: JSONValue?
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "turn/start")
            capturedParams = params
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-subagents")]),
                includeJSONRPC: false
            )
        }

        let viewModel = TurnViewModel()
        viewModel.input = "/sub"
        viewModel.slashCommandPanelState = .commands(query: "sub")
        viewModel.onSelectSlashCommand(.subagents)

        viewModel.sendTurn(codex: service, threadID: "thread-subagents")
        await waitForSendCompletion(viewModel)

        XCTAssertEqual(
            textInput(from: capturedParams),
            "Run subagents for different tasks. Delegate distinct work in parallel when helpful and then synthesize the results."
        )
    }

    func testSendTurnPrefixesDraftTextWhenSubagentsChipIsSelected() async {
        let service = makeService()
        service.isConnected = true

        var capturedParams: JSONValue?
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "turn/start")
            capturedParams = params
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-literal-subagents")]),
                includeJSONRPC: false
            )
        }

        let viewModel = TurnViewModel()
        viewModel.input = "/sub"
        viewModel.slashCommandPanelState = .commands(query: "sub")
        viewModel.onSelectSlashCommand(.subagents)

        viewModel.input = "Please explain what /subagents does."

        viewModel.sendTurn(codex: service, threadID: "thread-literal-subagents")
        await waitForSendCompletion(viewModel)

        XCTAssertEqual(
            textInput(from: capturedParams),
            "Run subagents for different tasks. Delegate distinct work in parallel when helpful and then synthesize the results.\n\nPlease explain what /subagents does."
        )
    }

    func testSendTurnPrefixesPromptBeforeOrdinaryDraftText() async {
        let service = makeService()
        service.isConnected = true

        var capturedParams: JSONValue?
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "turn/start")
            capturedParams = params
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-shifted-subagents")]),
                includeJSONRPC: false
            )
        }

        let viewModel = TurnViewModel()
        viewModel.input = "Please explain /subagents too."
        viewModel.isSubagentsSelectionArmed = true

        viewModel.sendTurn(codex: service, threadID: "thread-shifted-subagents")
        await waitForSendCompletion(viewModel)

        XCTAssertEqual(
            textInput(from: capturedParams),
            "Run subagents for different tasks. Delegate distinct work in parallel when helpful and then synthesize the results.\n\nPlease explain /subagents too."
        )
    }

    func testSendTurnTrimsLeadingWhitespaceBeforeApplyingSubagentsPrompt() async {
        let service = makeService()
        service.isConnected = true

        var capturedParams: JSONValue?
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "turn/start")
            capturedParams = params
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-trimmed-subagents")]),
                includeJSONRPC: false
            )
        }

        let viewModel = TurnViewModel()
        viewModel.input = "   follow up"
        viewModel.isSubagentsSelectionArmed = true

        viewModel.sendTurn(codex: service, threadID: "thread-trimmed-subagents")
        await waitForSendCompletion(viewModel)

        XCTAssertEqual(
            textInput(from: capturedParams),
            "Run subagents for different tasks. Delegate distinct work in parallel when helpful and then synthesize the results.\n\nfollow up"
        )
    }

    func testSendTurnPrefixesPromptAfterFileMentionRewrite() async {
        let service = makeService()
        service.isConnected = true

        var capturedParams: JSONValue?
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "turn/start")
            capturedParams = params
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-file-mention-subagents")]),
                includeJSONRPC: false
            )
        }

        let viewModel = TurnViewModel()
        viewModel.input = "@TurnView.swift /sub"
        viewModel.composerMentionedFiles = [
            TurnComposerMentionedFile(
                fileName: "TurnView.swift",
                path: "Views/Turn/TurnView.swift"
            )
        ]
        viewModel.slashCommandPanelState = .commands(query: "sub")
        viewModel.onSelectSlashCommand(.subagents)

        viewModel.sendTurn(codex: service, threadID: "thread-file-mention-subagents")
        await waitForSendCompletion(viewModel)

        XCTAssertEqual(
            textInput(from: capturedParams),
            "Run subagents for different tasks. Delegate distinct work in parallel when helpful and then synthesize the results.\n\n@Views/Turn/TurnView.swift"
        )
    }

    private func makeState(
        isSending: Bool = false,
        isConnected: Bool = true,
        trimmedInput: String = "hello",
        hasReadyImages: Bool = false,
        hasBlockingAttachmentState: Bool = false,
        hasSkillSelection: Bool = false,
        hasPluginSelection: Bool = false,
        hasReviewSelection: Bool = false,
        hasPendingReviewSelection: Bool = false,
        hasSubagentsSelection: Bool = false
    ) -> TurnComposerSendAvailability {
        TurnComposerSendAvailability(
            isSending: isSending,
            isConnected: isConnected,
            trimmedInput: trimmedInput,
            hasReadyImages: hasReadyImages,
            hasBlockingAttachmentState: hasBlockingAttachmentState,
            hasSkillSelection: hasSkillSelection,
            hasPluginSelection: hasPluginSelection,
            hasReviewSelection: hasReviewSelection,
            hasPendingReviewSelection: hasPendingReviewSelection,
            hasSubagentsSelection: hasSubagentsSelection
        )
    }

    private func makeAccessoryState(
        hasAttachment: Bool = false,
        hasSkillSelection: Bool = false
    ) -> TurnComposerAccessoryState {
        let attachment = CodexImageAttachment(
            thumbnailBase64JPEG: "thumb",
            payloadDataURL: "data:image/jpeg;base64,AAAA"
        )

        return TurnComposerAccessoryState(
            queuedDrafts: [],
            canSteerQueuedDrafts: false,
            canRestoreQueuedDrafts: false,
            steeringDraftID: nil,
            composerAttachments: hasAttachment ? [
                TurnComposerImageAttachment(id: "attachment-1", state: .ready(attachment))
            ] : [],
            composerMentionedFiles: [],
            composerMentionedSkills: hasSkillSelection ? [
                TurnComposerMentionedSkill(name: "check-code", path: "/skills/check-code/SKILL.md", description: "Review")
            ] : [],
            composerMentionedPlugins: [],
            composerReviewSelection: nil,
            isSubagentsSelectionArmed: false,
            isPlanModeArmed: false,
            isVoiceRecording: false,
            voiceAudioLevels: [],
            voiceRecordingDuration: 0
        )
    }

    private func waitForSendCompletion(_ viewModel: TurnViewModel, maxPollCount: Int = 120) async {
        for _ in 0..<maxPollCount where viewModel.isSending {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func textInput(from params: JSONValue?) -> String? {
        params?
            .objectValue?["input"]?
            .arrayValue?
            .compactMap(\.objectValue)
            .first(where: { $0["type"]?.stringValue == "text" })?["text"]?
            .stringValue
    }

    private func workspaceCheckpointResponse(kind: String, copied: Bool? = nil) -> RPCMessage {
        var result: RPCObject = [
            "repoRoot": .string("/tmp/remodex-local"),
            "checkpointRef": .string("refs/remodex/checkpoints/test"),
            "checkpointKind": .string(kind),
            "threadId": .string("thread-new"),
        ]
        if let copied {
            result["copied"] = .bool(copied)
        }
        return RPCMessage(
            id: .string(UUID().uuidString),
            result: .object(result),
            includeJSONRPC: false
        )
    }

    private func makeService() -> CodexService {
        let suiteName = "TurnComposerSendAvailabilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        service.messagesByThread = [:]
        service.composerDraftsByThreadID = [:]

        // CodexService currently crashes while deallocating in unit-test environment.
        // Keep instances alive for process lifetime so assertions remain deterministic.
        Self.retainedServices.append(service)
        return service
    }
}
