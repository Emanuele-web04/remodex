// FILE: ContentViewModelSidebarSyncTests.swift
// Purpose: Verifies sidebar-open sync requests stay out of the way during connection bootstrap loads.
// Layer: Unit Test
// Exports: ContentViewModelSidebarSyncTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class ContentViewModelSidebarSyncTests: XCTestCase {
    func testSidebarFreshSyncSkipsWhileBootstrappingConnectionSync() {
        let viewModel = ContentViewModel()

        let shouldRequest = viewModel.shouldRequestSidebarFreshSync(
            isConnected: true,
            isBootstrappingConnectionSync: true,
            isLoadingThreads: false,
            hasThreads: false
        )

        XCTAssertFalse(shouldRequest)
    }

    func testSidebarFreshSyncSkipsWhileThreadListLoadIsRunning() {
        let viewModel = ContentViewModel()

        let shouldRequest = viewModel.shouldRequestSidebarFreshSync(
            isConnected: true,
            isBootstrappingConnectionSync: false,
            isLoadingThreads: true,
            hasThreads: false
        )

        XCTAssertFalse(shouldRequest)
    }

    func testSidebarFreshSyncRequestsOnceWhenConnectedAndIdle() {
        let viewModel = ContentViewModel()

        let firstRequest = viewModel.shouldRequestSidebarFreshSync(
            isConnected: true,
            isBootstrappingConnectionSync: false,
            isLoadingThreads: false,
            hasThreads: false
        )
        let secondRequest = viewModel.shouldRequestSidebarFreshSync(
            isConnected: true,
            isBootstrappingConnectionSync: false,
            isLoadingThreads: false,
            hasThreads: false
        )

        XCTAssertTrue(firstRequest)
        XCTAssertFalse(secondRequest)
    }

    func testSidebarFreshSyncSkipsWhenThreadsAlreadyLoaded() {
        let viewModel = ContentViewModel()

        let shouldRequest = viewModel.shouldRequestSidebarFreshSync(
            isConnected: true,
            isBootstrappingConnectionSync: false,
            isLoadingThreads: false,
            hasThreads: true
        )

        XCTAssertFalse(shouldRequest)
    }
}
