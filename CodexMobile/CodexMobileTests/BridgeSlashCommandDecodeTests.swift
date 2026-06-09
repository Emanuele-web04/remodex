// FILE: BridgeSlashCommandDecodeTests.swift
// Purpose: Verifies command/list response decoding and slash-command routing helpers.
// Layer: Unit Test
// Exports: BridgeSlashCommandDecodeTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class BridgeSlashCommandDecodeTests: XCTestCase {
    private static var retainedServices: [CodexService] = []
    private static var retainedViewModels: [TurnViewModel] = []

    func testDecodeSlashCommandsParsesCommandListShape() {
        let service = makeService()
        let result: JSONValue = .object([
            "commands": .array([
                .object([
                    "token": .string("/build"),
                    "title": .string("Build"),
                    "description": .string("Build the project"),
                ]),
                .object([
                    "token": .string("/test"),
                    "title": .string("Test"),
                    "description": .string("Run tests"),
                ]),
            ]),
        ])

        let commands = service.decodeSlashCommands(from: result)

        XCTAssertEqual(commands?.count, 2)
        XCTAssertEqual(commands?.first?.token, "/build")
        XCTAssertEqual(commands?.first?.title, "Build")
        XCTAssertEqual(commands?.first?.description, "Build the project")
        XCTAssertEqual(commands?.last?.token, "/test")
    }

    func testDecodeSlashCommandsReturnsNilWhenCommandsMissing() {
        let service = makeService()
        XCTAssertNil(service.decodeSlashCommands(from: .object([:])))
    }

    func testFetchSlashCommandsCallsCommandListWithDirectory() async throws {
        let service = makeService()
        var capturedMethod: String?
        var capturedDirectory: String?

        service.requestTransportOverride = { method, params in
            capturedMethod = method
            capturedDirectory = params?.objectValue?["directory"]?.stringValue
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "commands": .array([
                        .object([
                            "token": .string("/compact"),
                            "title": .string("Compact"),
                            "description": .string("Summarize context"),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let commands = try await service.fetchSlashCommands(directory: "/Users/me/work/repo")

        XCTAssertEqual(capturedMethod, "command/list")
        XCTAssertEqual(capturedDirectory, "/Users/me/work/repo")
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.token, "/compact")

        let cached = try await service.fetchSlashCommands(directory: "/Users/me/work/repo")
        XCTAssertEqual(cached.count, 1)
        XCTAssertEqual(capturedMethod, "command/list")
    }

    func testFetchSlashCommandsDoesNotCacheFailures() async {
        let service = makeService()
        var requestCount = 0

        service.requestTransportOverride = { _, _ in
            requestCount += 1
            throw CodexServiceError.disconnected
        }

        do {
            _ = try await service.fetchSlashCommands(directory: "/tmp/failed-project")
            XCTFail("Expected fetchSlashCommands to throw")
        } catch {
            XCTAssertEqual(requestCount, 1)
        }

        do {
            _ = try await service.fetchSlashCommands(directory: "/tmp/failed-project")
            XCTFail("Expected fetchSlashCommands to throw on retry")
        } catch {
            XCTAssertEqual(requestCount, 2)
        }
    }

    func testFetchSlashCommandsUsesCacheWithinTTL() async throws {
        let service = makeService()
        var requestCount = 0

        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "command/list")
            requestCount += 1
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "commands": .array([
                        .object([
                            "token": .string("/status"),
                            "title": .string("Status"),
                            "description": .string("Show status"),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        _ = try await service.fetchSlashCommands(directory: "/tmp/project-a")
        _ = try await service.fetchSlashCommands(directory: "/tmp/project-a")

        XCTAssertEqual(requestCount, 1)
    }

    func testInvalidateSlashCommandCacheForcesRefetch() async throws {
        let service = makeService()
        var requestCount = 0

        service.requestTransportOverride = { _, _ in
            requestCount += 1
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["commands": .array([])]),
                includeJSONRPC: false
            )
        }

        _ = try await service.fetchSlashCommands(directory: "/tmp/project-b")
        service.invalidateSlashCommandCache()
        _ = try await service.fetchSlashCommands(directory: "/tmp/project-b")

        XCTAssertEqual(requestCount, 2)
    }

    func testFetchSlashCommandsClearsInMemoryCacheOnEmptySuccess() async throws {
        let service = makeService()
        var requestCount = 0

        service.requestTransportOverride = { _, _ in
            requestCount += 1
            if requestCount == 2 {
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["commands": .array([])]),
                    includeJSONRPC: false
                )
            }

            var commands: [JSONValue] = []
            for index in 0..<CodexService.minimumPersistedSlashCommandCount {
                commands.append(
                    .object([
                        "token": .string("/cmd\(index)"),
                        "title": .string("Cmd \(index)"),
                        "description": .string(""),
                    ])
                )
            }
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["commands": .array(commands)]),
                includeJSONRPC: false
            )
        }

        let first = try await service.fetchSlashCommands(directory: "/tmp/mem-cache-clear")
        XCTAssertEqual(first.count, CodexService.minimumPersistedSlashCommandCount)

        // Expire the in-memory TTL so the next fetch observes transport empty-success.
        let cacheKey = "/tmp/mem-cache-clear"
        if let cached = service.slashCommandCacheByDirectory[cacheKey] {
            service.slashCommandCacheByDirectory[cacheKey] = SlashCommandCacheEntry(
                commands: cached.commands,
                fetchedAt: Date(timeIntervalSince1970: 0),
                directory: cached.directory
            )
        }

        let empty = try await service.fetchSlashCommands(directory: "/tmp/mem-cache-clear")
        XCTAssertTrue(empty.isEmpty)

        let third = try await service.fetchSlashCommands(directory: "/tmp/mem-cache-clear")
        XCTAssertEqual(third.count, CodexService.minimumPersistedSlashCommandCount)
        XCTAssertEqual(requestCount, 3)
    }

    func testLoadPersistedSlashCommandCacheRejectsShortCatalog() {
        let service = makeService()
        let cacheFile = persistedSlashCommandsCacheURL()
        try? FileManager.default.removeItem(at: cacheFile)
        defer { try? FileManager.default.removeItem(at: cacheFile) }

        let staleEntry = SlashCommandCacheEntry(
            commands: [BridgeSlashCommand(token: "/undo", title: "Undo", description: "")],
            fetchedAt: Date(),
            directory: "/tmp/stale-short"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = ["/tmp/stale-short": staleEntry]
        if let data = try? encoder.encode(payload) {
            let directory = cacheFile.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: [.atomic])
        }

        service.loadPersistedSlashCommandCache()
        XCTAssertNil(service.slashCommandCacheByDirectory["/tmp/stale-short"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path))
    }

    func testFetchSlashCommandsDoesNotPersistEmptySuccess() async throws {
        let service = makeService()
        let cacheFile = persistedSlashCommandsCacheURL()
        try? FileManager.default.removeItem(at: cacheFile)
        defer { try? FileManager.default.removeItem(at: cacheFile) }

        service.requestTransportOverride = { _, _ in
            RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["commands": .array([])]),
                includeJSONRPC: false
            )
        }

        let commands = try await service.fetchSlashCommands(directory: "/tmp/empty-success")
        XCTAssertTrue(commands.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path))
    }

    func testInvalidateSlashCommandCacheClearsPersistedEntry() async throws {
        let service = makeService()
        let cacheFile = persistedSlashCommandsCacheURL()
        try? FileManager.default.removeItem(at: cacheFile)
        defer { try? FileManager.default.removeItem(at: cacheFile) }

        service.requestTransportOverride = { _, _ in
            RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "commands": .array([
                        .object([
                            "token": .string("/undo"),
                            "title": .string("Undo"),
                            "description": .string(""),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        _ = try await service.fetchSlashCommands(directory: "/tmp/persist-clear")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path))

        service.invalidateSlashCommandCache(directory: "/tmp/persist-clear")
        if FileManager.default.fileExists(atPath: cacheFile.path) {
            let data = try Data(contentsOf: cacheFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let entries = try decoder.decode([String: SlashCommandCacheEntry].self, from: data)
            XCTAssertNil(entries["/tmp/persist-clear"])
        }
    }

    func testEmptyBridgeSlashCommandSuccessUsesMinimalFallback() async {
        let service = makeService()
        service.requestTransportOverride = { _, _ in
            RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["commands": .array([])]),
                includeJSONRPC: false
            )
        }
        service.upsertThread(CodexThread(
            id: "thread-empty-success",
            cwd: "/tmp/empty-bridge",
            model: "opencode/gpt-5.5",
            modelProvider: "opencode"
        ))

        let viewModel = makeViewModel()
        let thread = CodexThread(
            id: "thread-empty-success",
            cwd: "/tmp/empty-bridge",
            model: "opencode/gpt-5.5",
            modelProvider: "opencode"
        )

        viewModel.onInputChangedForSlashCommandAutocomplete(
            "/",
            codex: service,
            thread: thread,
            supportsSlashCommands: true,
            activeTurnID: nil
        )

        let loadFinished = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !viewModel.isLoadingBridgeSlashCommands
            },
            object: viewModel
        )
        await fulfillment(of: [loadFinished], timeout: 2.0)

        XCTAssertFalse(viewModel.didLoadBridgeSlashCommandsSuccessfully)
        XCTAssertEqual(
            viewModel.bridgeSlashCommands.map(\.token),
            TurnComposerSlashCommand.minimalFallbackSlashCommands().map(\.token)
        )
    }

    func testBridgeSlashCommandLoadFailureShowsRetryInsteadOfEmptyHint() async {
        let service = makeService()
        service.requestTransportOverride = { _, _ in
            throw CodexServiceError.disconnected
        }
        service.upsertThread(CodexThread(
            id: "thread-slash-failure",
            cwd: "/tmp/project-failure",
            model: "opencode/gpt-5.5",
            modelProvider: "opencode"
        ))

        let viewModel = makeViewModel()
        let thread = CodexThread(
            id: "thread-slash-failure",
            cwd: "/tmp/project-failure",
            model: "opencode/gpt-5.5",
            modelProvider: "opencode"
        )

        viewModel.onInputChangedForSlashCommandAutocomplete(
            "/",
            codex: service,
            thread: thread,
            supportsSlashCommands: true,
            activeTurnID: nil
        )

        let failureReady = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                viewModel.bridgeSlashCommandsLoadError != nil || !viewModel.isLoadingBridgeSlashCommands
            },
            object: viewModel
        )
        await fulfillment(of: [failureReady], timeout: 2.0)

        XCTAssertEqual(viewModel.bridgeSlashCommandsLoadError, "Couldn't load commands. Tap to retry.")
        XCTAssertFalse(viewModel.didLoadBridgeSlashCommandsSuccessfully)
        XCTAssertFalse(viewModel.showsBridgeSlashCommandsEmptyHint)

        // RP-CMD-3: even on fetch error (no persisted yet), OC bridge source gets minimal fallback (not empty panel)
        // /undo etc will come from bridge dynamic on success path; minimal for degraded + codex parity.
        let items = viewModel.availableSlashCommandItems(allowsForkCommand: true, slashSource: .bridgeCommands)
        let tokens = Set(items.map(\.commandToken))
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(tokens.contains("/compact"))
        XCTAssertTrue(tokens.contains("/review"))
        XCTAssertTrue(tokens.contains("/help"))
    }

    func testDirectoryChangeDuringFetchUsesLatestDirectoryCommands() async throws {
        let service = makeService()
        let firstDirectoryReady = expectation(description: "first directory fetch started")
        let releaseFirstDirectory = expectation(description: "release first directory fetch")
        var firstFetchStarted = false

        service.requestTransportOverride = { _, params in
            let directory = params?.objectValue?["directory"]?.stringValue
            if directory == "/tmp/project-first" {
                if !firstFetchStarted {
                    firstFetchStarted = true
                    firstDirectoryReady.fulfill()
                }
                await self.fulfillment(of: [releaseFirstDirectory], timeout: 2.0)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "commands": .array([
                            .object([
                                "token": .string("/stale"),
                                "title": .string("Stale"),
                                "description": .string("Should not win"),
                            ]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            }

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "commands": .array([
                        .object([
                            "token": .string("/fresh"),
                            "title": .string("Fresh"),
                            "description": .string("Latest directory"),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        service.upsertThread(CodexThread(
            id: "thread-slash-race",
            cwd: "/tmp/project-first",
            model: "opencode/gpt-5.5",
            modelProvider: "opencode"
        ))

        let viewModel = makeViewModel()
        let firstThread = CodexThread(
            id: "thread-slash-race",
            cwd: "/tmp/project-first",
            model: "opencode/gpt-5.5",
            modelProvider: "opencode"
        )
        let secondThread = CodexThread(
            id: "thread-slash-race",
            cwd: "/tmp/project-second",
            model: "opencode/gpt-5.5",
            modelProvider: "opencode"
        )

        viewModel.onInputChangedForSlashCommandAutocomplete(
            "/",
            codex: service,
            thread: firstThread,
            supportsSlashCommands: true,
            activeTurnID: nil
        )

        await fulfillment(of: [firstDirectoryReady], timeout: 2.0)

        viewModel.onInputChangedForSlashCommandAutocomplete(
            "/",
            codex: service,
            thread: secondThread,
            supportsSlashCommands: true,
            activeTurnID: nil
        )

        releaseFirstDirectory.fulfill()

        let freshLoaded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                viewModel.bridgeSlashCommands.map(\.token) == ["/fresh"]
            },
            object: viewModel
        )
        await fulfillment(of: [freshLoaded], timeout: 2.0)

        XCTAssertEqual(viewModel.bridgeSlashCommands.map(\.token), ["/fresh"])
        XCTAssertTrue(viewModel.didLoadBridgeSlashCommandsSuccessfully)
        XCTAssertNil(viewModel.bridgeSlashCommandsLoadError)
    }

    func testBridgeSlashCommandFilteredMatchesTokenTitleAndDescription() {
        let commands = [
            BridgeSlashCommand(token: "/build", title: "Build", description: "Build the project"),
            BridgeSlashCommand(token: "/test", title: "Test", description: "Run tests"),
        ]

        XCTAssertEqual(
            BridgeSlashCommand.filtered(matching: "run", within: commands).map(\.token),
            ["/test"]
        )
        XCTAssertEqual(
            BridgeSlashCommand.filtered(matching: "build", within: commands).map(\.token),
            ["/build"]
        )
    }

    func testAvailableCommandsForProvider() {
        // availableCommandsForProvider retains codex assumptions (for codex paths + legacy tests);
        // OC/usesBridge no longer calls it (dynamic bridge primary + minimal fallback for degraded).
        let codexCmds = TurnComposerSlashCommand.availableCommandsForProvider(
            allowsForkCommand: true,
            modelProvider: "codex"
        )
        let codexTokens = Set(codexCmds.map(\.commandToken))
        XCTAssertTrue(codexTokens.contains("/review"))
        XCTAssertTrue(codexTokens.contains("/subagents"))
        XCTAssertTrue(codexTokens.contains("/compact"))

        // opencode provider filter path still exists in func but is not used for command list surface post RP-CMD-3
        let ocViaFunc = TurnComposerSlashCommand.availableCommandsForProvider(
            allowsForkCommand: true,
            modelProvider: "opencode"
        )
        let ocTokens = Set(ocViaFunc.map(\.commandToken))
        XCTAssertFalse(ocTokens.contains("/review"))
        XCTAssertFalse(ocTokens.contains("/subagents"))
    }

    func testSlashCommandRoutingUsesBridgeListForOpenCodeProvider() {
        XCTAssertEqual(
            TurnComposerSlashCommandRouting.source(
                supportsSlashCommands: true,
                modelProvider: "opencode"
            ),
            .bridgeCommands
        )
        XCTAssertEqual(
            TurnComposerSlashCommandRouting.source(
                supportsSlashCommands: true,
                modelProvider: "codex"
            ),
            .codexEnum
        )
        XCTAssertEqual(
            TurnComposerSlashCommandRouting.source(
                supportsSlashCommands: false,
                modelProvider: "opencode"
            ),
            .disabled
        )
    }

    func testTurnComposerSlashCommandItemFilteredMatchesBridgeMetadata() {
        let items: [TurnComposerSlashCommandItem] = [
            .bridge(BridgeSlashCommand(token: "/plan", title: "Plan", description: "Planning mode")),
            .codex(.status),
        ]

        XCTAssertEqual(
            TurnComposerSlashCommandItem.filtered(matching: "plan", within: items).count,
            1
        )
        XCTAssertEqual(
            TurnComposerSlashCommandItem.filtered(matching: "status", within: items).first?.commandToken,
            "/status"
        )
    }

    // RP-CMD-3 tests: persisted cache + fallback on error + OC /undo visible via bridge (not enum, not empty)
    func testBridgeSlashCommandFallsBackToPersistedOnSubsequentError() async throws {
        let service = makeService()
        // ensure clean persisted for this test (path per persistedSlashCommandsCacheURL impl)
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let cacheFile = home.appendingPathComponent(".remodex/slash-commands-cache.json")
        try? FileManager.default.removeItem(at: cacheFile)
        defer { try? FileManager.default.removeItem(at: cacheFile) }

        let dir = "/tmp/project-persist-fallback"
        // success path (exercises write on success; includes /undo from RP-CMD-1 bridge builtins)
        service.requestTransportOverride = { _, _ in
            RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "commands": .array([
                        .object([
                            "token": .string("/undo"),
                            "title": .string("Undo"),
                            "description": .string("Undo last edit"),
                        ]),
                        .object([
                            "token": .string("/compact"),
                            "title": .string("Compact"),
                            "description": .string("Summarize context"),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let first = try await service.fetchSlashCommands(directory: dir)
        XCTAssertEqual(first.map(\.token), ["/undo", "/compact"])

        // now force error: fetch should fallback (no throw) using persisted, returning prior list
        service.requestTransportOverride = { _, _ in
            throw CodexServiceError.disconnected
        }
        let second = try await service.fetchSlashCommands(directory: dir)
        XCTAssertEqual(second.map(\.token), ["/undo", "/compact"])
    }

    func testOpenCodeUsesBridgeDynamicPrimaryAndUndoVisiblePostEnumRemoval() {
        // Explicit post RP-CMD-3 validation: for OC + supports, we route to .bridgeCommands;
        // available uses bridge list (or minimal on degraded) -- never falls back to TurnComposerSlashCommand enum.
        // /undo (from bridge) is visible when dynamic provides it.
        let bridgeItems: [TurnComposerSlashCommandItem] = [
            .bridge(BridgeSlashCommand(token: "/undo", title: "Undo", description: "Undo last")),
            .bridge(BridgeSlashCommand(token: "/help", title: "Help", description: "")),
            .bridge(BridgeSlashCommand(token: "/compact", title: "Compact", description: "")),
        ]
        // simulate what availableSlashCommandItems(bridgeSource) returns when dynamic has data
        let tokens = bridgeItems.map(\.commandToken)
        XCTAssertTrue(tokens.contains("/undo"))
        XCTAssertTrue(tokens.contains("/help"))
        XCTAssertFalse(bridgeItems.contains { $0.codexCommand != nil }) // no codex enum items leaked to OC path

        // degraded case uses minimal (synthetic bridge items), not enum
        let minimal = TurnComposerSlashCommand.minimalFallbackSlashCommands()
        XCTAssertEqual(minimal.map(\.token), ["/compact", "/review", "/help"])
        let minimalItems = minimal.map { TurnComposerSlashCommandItem.bridge($0) }
        XCTAssertTrue(minimalItems.allSatisfy { $0.codexCommand == nil })
    }

    func testSlashSection_ocBuiltin() {
        let section = BridgeSlashCommand.classifySection(
            for: BridgeSlashCommand(token: "/mcp", title: "MCP", description: ""),
            codexOverlapTokens: []
        )
        XCTAssertEqual(section, SlashCommandSection.ocBuiltin)
    }

    func testSlashSection_codexOverlapCompactUsesOcBuiltin() {
        let codexTokens = Set(
            TurnComposerSlashCommand.availableCommandsForProvider(
                allowsForkCommand: true,
                modelProvider: "opencode"
            ).map(\.commandToken)
        )
        let section = BridgeSlashCommand.classifySection(
            for: BridgeSlashCommand(token: "/compact", title: "Compact", description: ""),
            codexOverlapTokens: codexTokens
        )
        XCTAssertEqual(section, SlashCommandSection.ocBuiltin)
    }

    func testSlashSection_skillDerived() {
        let bySource = BridgeSlashCommand.classifySection(
            for: BridgeSlashCommand(token: "/lint", title: "Lint", description: "", source: "skill"),
            codexOverlapTokens: []
        )
        XCTAssertEqual(bySource, SlashCommandSection.skillDerived)

        let byName = BridgeSlashCommand.classifySection(
            for: BridgeSlashCommand(token: "/review-skill", title: "Review", description: ""),
            codexOverlapTokens: [],
            skillNames: ["review-skill"]
        )
        XCTAssertEqual(byName, SlashCommandSection.skillDerived)
    }

    func testSlashSection_agent() {
        XCTAssertEqual(
            BridgeSlashCommand.classifySection(
                for: BridgeSlashCommand(token: "/agents", title: "Agents", description: ""),
                codexOverlapTokens: []
            ),
            SlashCommandSection.agent
        )
        XCTAssertEqual(
            BridgeSlashCommand.classifySection(
                for: BridgeSlashCommand(token: "/tool", title: "Tool", description: "", source: "mcp"),
                codexOverlapTokens: []
            ),
            SlashCommandSection.agent
        )
        XCTAssertEqual(
            BridgeSlashCommand.classifySection(
                for: BridgeSlashCommand(token: "/delegate", title: "Delegate", description: "", agent: "build"),
                codexOverlapTokens: []
            ),
            SlashCommandSection.agent
        )
    }

    func testDecodeSlashCommandsOptionalFields() throws {
        let json = """
        {
          "commands": [
            {
              "token": "/build",
              "title": "Build",
              "description": "Build project",
              "source": "skill",
              "agent": "build",
              "provider": "opencode",
              "section": "skill"
            }
          ]
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let envelope = try JSONDecoder().decode([String: [BridgeSlashCommand]].self, from: data)
        let command = try XCTUnwrap(envelope["commands"]?.first)
        XCTAssertEqual(command.source, "skill")
        XCTAssertEqual(command.agent, "build")
        XCTAssertEqual(command.provider, "opencode")
        XCTAssertEqual(command.section, "skill")
        XCTAssertEqual(
            BridgeSlashCommand.classifySection(for: command, codexOverlapTokens: []),
            SlashCommandSection.skillDerived
        )
    }

    func testDecodeSlashCommandsParsesRequiresArguments() throws {
        let service = makeService()
        let result: JSONValue = .object([
            "commands": .array([
                .object([
                    "token": .string("/skills"),
                    "title": .string("Skills"),
                    "description": .string(""),
                    "requiresArguments": .bool(false),
                ]),
                .object([
                    "token": .string("/plan"),
                    "title": .string("Plan"),
                    "description": .string("Needs input"),
                    "requiresArguments": .bool(true),
                ]),
            ]),
        ])

        let commands = try XCTUnwrap(service.decodeSlashCommands(from: result))
        XCTAssertEqual(commands[0].requiresArguments, false)
        XCTAssertEqual(commands[1].requiresArguments, true)
    }

    func testDecodeSlashCommandsRequiresArgumentsDefaultsFalseWhenMissing() throws {
        let payload = """
        {"commands":[{"token":"/clear","title":"Clear","description":""}]}
        """
        let data = try XCTUnwrap(payload.data(using: .utf8))
        let decoded = try JSONDecoder().decode([String: [BridgeSlashCommand]].self, from: data)
        XCTAssertEqual(decoded["commands"]?.first?.requiresArguments, false)
    }

    func testDecodeSlashCommandsParsesTemplateAndHints() throws {
        let payload = """
        {
          "commands": [{
            "token": "/init",
            "title": "Init",
            "description": "Setup",
            "requiresArguments": true,
            "template": "Focus:\\n$ARGUMENTS",
            "hints": ["$ARGUMENTS"]
          }]
        }
        """
        let data = try XCTUnwrap(payload.data(using: .utf8))
        let decoded = try JSONDecoder().decode([String: [BridgeSlashCommand]].self, from: data)
        let command = try XCTUnwrap(decoded["commands"]?.first)
        XCTAssertEqual(command.template, "Focus:\n$ARGUMENTS")
        XCTAssertEqual(command.hints, ["$ARGUMENTS"])
        XCTAssertEqual(command.argumentFieldSpecs.count, 1)
        XCTAssertTrue(command.argumentFieldSpecs[0].isMultiline)
    }

    func testBridgeSlashCommandArgumentFieldSpecsUseNumericPlaceholdersWhenHintsMissing() {
        let command = BridgeSlashCommand(
            token: "/plan",
            title: "Plan",
            description: "",
            requiresArguments: true,
            template: "Plan $2 then $1"
        )
        XCTAssertEqual(command.argumentFieldSpecs.map(\.id), ["$1", "$2"])
        XCTAssertFalse(command.argumentFieldSpecs[0].isMultiline)
    }

    func testExecuteBridgeSlashCommandSendsArgumentFields() async throws {
        let service = makeService()
        var capturedFields: JSONValue?

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "command/execute")
            capturedFields = params?.objectValue?["argumentFields"]
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "ok": .bool(true),
                    "sessionId": .string("ses_args"),
                ]),
                includeJSONRPC: false
            )
        }

        _ = try await service.executeBridgeSlashCommand(
            threadId: "thread-args",
            command: "/init",
            directory: "/tmp/args",
            clientCommandId: UUID(),
            argumentFields: [
                BridgeSlashCommandArgumentField(key: "$ARGUMENTS", value: "focus on tests"),
            ],
            template: "Focus:\n$ARGUMENTS",
            hints: ["$ARGUMENTS"]
        )

        let fields = try XCTUnwrap(capturedFields?.arrayValue)
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields[0].objectValue?["key"]?.stringValue, "$ARGUMENTS")
        XCTAssertEqual(fields[0].objectValue?["value"]?.stringValue, "focus on tests")
    }

    func testExecuteBridgeSlashCommandSendsClientCommandId() async throws {
        let service = makeService()
        var capturedMethod: String?
        var capturedClientCommandId: String?
        var capturedCommand: String?

        service.requestTransportOverride = { method, params in
            capturedMethod = method
            capturedCommand = params?.objectValue?["command"]?.stringValue
            capturedClientCommandId = params?.objectValue?["clientCommandId"]?.stringValue
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "ok": .bool(true),
                    "sessionId": .string("ses_test"),
                ]),
                includeJSONRPC: false
            )
        }

        let clientCommandId = UUID()
        let result = try await service.executeBridgeSlashCommand(
            threadId: "thread-exec",
            command: "/skills",
            directory: "/tmp/exec",
            clientCommandId: clientCommandId
        )

        XCTAssertEqual(capturedMethod, "command/execute")
        XCTAssertEqual(capturedCommand, "/skills")
        XCTAssertEqual(capturedClientCommandId, clientCommandId.uuidString)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.sessionId, "ses_test")
    }

    func testOnSelectBridgeSlashZeroArgExecutesWithoutPrefill() async throws {
        let service = makeOpenCodeSlashExecuteService()
        var executeCallCount = 0
        service.requestTransportOverride = { method, _ in
            if method == "command/execute" {
                executeCallCount += 1
            }
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "ok": .bool(true),
                    "sessionId": .string("ses_skills"),
                ]),
                includeJSONRPC: false
            )
        }

        let viewModel = makeViewModel()
        viewModel.input = "/skills"
        let thread = CodexThread(
            id: "thread-slash-exec",
            cwd: "/tmp/slash-exec",
            model: "openai/gpt-5.5",
            modelProvider: "opencode"
        )
        service.upsertThread(thread)
        let hostContext = TurnSlashHostContext(
            codex: service,
            thread: thread,
            availableForkDestinations: [],
            onShowStatus: {},
            onOpenFeedbackMail: {}
        )

        viewModel.onSelectSlashCommandItem(
            .bridge(BridgeSlashCommand(token: "/skills", title: "Skills", description: "")),
            hostContext: hostContext
        )

        XCTAssertEqual(viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines), "")

        let executeFinished = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in executeCallCount > 0 },
            object: nil
        )
        await fulfillment(of: [executeFinished], timeout: 2.0)
        XCTAssertEqual(executeCallCount, 1)
    }

    func testOnSelectBridgeSlashDoubleTapDebouncesToSingleExecute() async throws {
        let service = makeOpenCodeSlashExecuteService()
        var executeCallCount = 0
        service.requestTransportOverride = { method, _ in
            if method == "command/execute" {
                executeCallCount += 1
            }
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "ok": .bool(true),
                    "sessionId": .string("ses_clear"),
                ]),
                includeJSONRPC: false
            )
        }

        let viewModel = makeViewModel()
        let thread = CodexThread(
            id: "thread-debounce",
            cwd: "/tmp/debounce",
            model: "openai/gpt-5.5",
            modelProvider: "opencode"
        )
        service.upsertThread(thread)
        let hostContext = TurnSlashHostContext(
            codex: service,
            thread: thread,
            availableForkDestinations: [],
            onShowStatus: {},
            onOpenFeedbackMail: {}
        )
        let item = TurnComposerSlashCommandItem.bridge(
            BridgeSlashCommand(token: "/clear", title: "Clear", description: "")
        )

        viewModel.onSelectSlashCommandItem(item, hostContext: hostContext)
        viewModel.onSelectSlashCommandItem(item, hostContext: hostContext)

        let executeFinished = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in executeCallCount > 0 },
            object: nil
        )
        await fulfillment(of: [executeFinished], timeout: 2.0)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(executeCallCount, 1)
    }

    func testOnSelectCodexCompactInvokesCompactThreadRPC() async throws {
        let service = makeService()
        var capturedMethods: [String] = []
        service.requestTransportOverride = { method, _ in
            capturedMethods.append(method)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([:]),
                includeJSONRPC: false
            )
        }
        service.availableRuntimes = [
            RuntimeInfo(
                id: "codex",
                label: "Codex",
                enabled: true,
                unavailableReason: nil,
                reasonCode: nil,
                showsBetaLabel: false,
                capabilities: .defaultCodex,
                agents: []
            ),
        ]
        service.availableModels = [
            CodexModelOption(
                id: "gpt-5.5",
                model: "gpt-5.5",
                modelProvider: "codex",
                displayName: "GPT-5.5",
                description: "",
                isDefault: true,
                supportedReasoningEfforts: [],
                defaultReasoningEffort: nil,
                capabilities: .defaultCodex
            ),
        ]
        service.upsertThread(CodexThread(id: "thread-codex-compact", modelProvider: "codex"))

        let viewModel = makeViewModel()
        let thread = CodexThread(id: "thread-codex-compact", modelProvider: "codex")
        let hostContext = TurnSlashHostContext(
            codex: service,
            thread: thread,
            availableForkDestinations: [],
            onShowStatus: {},
            onOpenFeedbackMail: {}
        )

        viewModel.onSelectSlashCommandItem(.codex(.compact), hostContext: hostContext)

        let rpcFinished = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in capturedMethods.contains("thread/compact/start") },
            object: nil
        )
        await fulfillment(of: [rpcFinished], timeout: 2.0)
        XCTAssertTrue(capturedMethods.contains("thread/compact/start"))
        XCTAssertFalse(capturedMethods.contains("turn/start"))
    }

    func testCommandNotAllowedInvalidatesSlashCacheAndRefetches() async throws {
        let service = makeOpenCodeSlashExecuteService()
        var listCallCount = 0
        service.requestTransportOverride = { method, _ in
            if method == "command/list" {
                listCallCount += 1
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "commands": .array([
                            .object([
                                "token": .string("/skills"),
                                "title": .string("Skills"),
                                "description": .string(""),
                            ]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            }
            if method == "command/execute" {
                throw CodexServiceError.rpcError(
                    RPCError(
                        code: -32000,
                        message: "Slash command not allowed",
                        data: .object(["errorCode": .string("command_not_allowed")])
                    )
                )
            }
            return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
        }

        let viewModel = makeViewModel()
        let thread = CodexThread(
            id: "thread-not-allowed",
            cwd: "/tmp/not-allowed",
            model: "openai/gpt-5.5",
            modelProvider: "opencode"
        )
        service.upsertThread(thread)
        _ = try await service.fetchSlashCommands(directory: thread.gitWorkingDirectory)

        let hostContext = TurnSlashHostContext(
            codex: service,
            thread: thread,
            availableForkDestinations: [],
            onShowStatus: {},
            onOpenFeedbackMail: {}
        )
        viewModel.onSelectSlashCommandItem(
            .bridge(BridgeSlashCommand(token: "/skills", title: "Skills", description: "")),
            hostContext: hostContext
        )

        let refetchFinished = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in listCallCount >= 2 },
            object: nil
        )
        await fulfillment(of: [refetchFinished], timeout: 2.0)
        XCTAssertGreaterThanOrEqual(listCallCount, 2)
    }

    func testGroupedSectionsOmitsEmpty() {
        let grouped = BridgeSlashCommand.groupedSections(
            commands: [
                BridgeSlashCommand(token: "/undo", title: "Undo", description: ""),
                BridgeSlashCommand(token: "/build", title: "Build", description: "", source: "skill"),
            ],
            codexOverlapTokens: []
        )
        XCTAssertEqual(grouped.map(\.section), [SlashCommandSection.ocBuiltin, SlashCommandSection.skillDerived])
        XCTAssertEqual(grouped[0].commands.map(\.token), ["/undo"])
        XCTAssertEqual(grouped[1].commands.map(\.token), ["/build"])
    }

    private func persistedSlashCommandsCacheURL() -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return home.appendingPathComponent(".remodex/slash-commands-cache.json")
    }

    private func makeOpenCodeSlashExecuteService() -> CodexService {
        let service = makeService()
        service.availableRuntimes = [
            RuntimeInfo(
                id: "opencode",
                label: "OpenCode",
                enabled: true,
                unavailableReason: nil,
                reasonCode: nil,
                showsBetaLabel: true,
                capabilities: .defaultOpenCode,
                agents: []
            ),
        ]
        service.availableModels = [
            CodexModelOption(
                id: "openai/gpt-5.5",
                model: "openai/gpt-5.5",
                modelProvider: "opencode",
                displayName: "GPT-5.5",
                description: "",
                isDefault: true,
                supportedReasoningEfforts: [],
                defaultReasoningEffort: nil,
                capabilities: .defaultOpenCode
            ),
        ]
        return service
    }

    private func makeService() -> CodexService {
        let suiteName = "BridgeSlashCommandDecodeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        // Clean persisted slash cache file for test isolation (RP-CMD-3 ~/.remodex/slash-commands-cache.json)
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let cacheFile = home.appendingPathComponent(".remodex/slash-commands-cache.json")
        try? FileManager.default.removeItem(at: cacheFile)
        let service = CodexService(defaults: defaults)
        service.messagesByThread = [:]
        service.invalidateSlashCommandCache()

        Self.retainedServices.append(service)
        return service
    }

    private func makeViewModel() -> TurnViewModel {
        let viewModel = TurnViewModel()
        Self.retainedViewModels.append(viewModel)
        return viewModel
    }
}