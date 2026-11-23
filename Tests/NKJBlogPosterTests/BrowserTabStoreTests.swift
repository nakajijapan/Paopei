import Foundation
import XCTest
@testable import NKJBlogPoster

@MainActor
final class BrowserTabStoreTests: XCTestCase {
    func testWorkspaceStartsOnPreviewAndPreservesTheInitialBrowserTab() throws {
        let browserTabs = BrowserTabStore()
        let workspace = PreviewWorkspaceStore(browserTabs: browserTabs)
        let initialID = try XCTUnwrap(browserTabs.selectedTab?.id)

        XCTAssertFalse(workspace.isBrowserSelected(initialID))
        XCTAssertTrue(workspace.isPreviewSelected)
        XCTAssertEqual(browserTabs.selectedTabID, initialID)
    }

    func testWorkspaceKeepsBrowserTabsWhilePreviewIsSelected() throws {
        let browserTabs = BrowserTabStore()
        let workspace = PreviewWorkspaceStore(browserTabs: browserTabs)
        let firstBrowserTabID = try XCTUnwrap(browserTabs.selectedTab?.id)

        workspace.selectBrowser(firstBrowserTabID)
        workspace.addBrowserTab()
        let secondBrowserTabID = try XCTUnwrap(browserTabs.selectedTab?.id)
        workspace.selectPreview()

        XCTAssertTrue(workspace.isPreviewSelected)
        XCTAssertEqual(browserTabs.tabs.map(\.id), [firstBrowserTabID, secondBrowserTabID])
        XCTAssertEqual(browserTabs.selectedTabID, secondBrowserTabID)

        workspace.selectBrowser(firstBrowserTabID)
        XCTAssertTrue(workspace.isBrowserSelected(firstBrowserTabID))
        XCTAssertEqual(browserTabs.tabs.count, 2)
    }

    func testClosingSelectedBrowserTabKeepsWorkspaceOnReplacementBrowserTab() throws {
        let browserTabs = BrowserTabStore()
        let workspace = PreviewWorkspaceStore(browserTabs: browserTabs)
        let firstBrowserTabID = try XCTUnwrap(browserTabs.selectedTab?.id)
        workspace.addBrowserTab()
        let secondBrowserTabID = try XCTUnwrap(browserTabs.selectedTab?.id)

        workspace.closeBrowserTab(secondBrowserTabID)

        XCTAssertEqual(browserTabs.selectedTabID, firstBrowserTabID)
        XCTAssertTrue(workspace.isBrowserSelected(firstBrowserTabID))
    }

    func testStartsWithOneTabAndNewTabSelectsIndependentTab() {
        let store = BrowserTabStore()
        let firstID = try! XCTUnwrap(store.selectedTab?.id)

        store.setSelectedAddress("example.com")
        store.loadSelectedAddress()
        store.addTab()

        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertNotEqual(store.selectedTabID, firstID)
        XCTAssertEqual(store.tabs.first(where: { $0.id == firstID })?.address, "https://example.com")
        XCTAssertEqual(store.selectedTab?.displayTitle, "新規タブ")
    }

    func testPerTabNavigationStateAndTitleAreIndependent() throws {
        let store = BrowserTabStore()
        let firstID = try XCTUnwrap(store.selectedTab?.id)
        let firstURL = try XCTUnwrap(URL(string: "https://first.example.com/article"))
        store.navigationStarted(for: firstID)
        store.navigationFinished(
            for: firstID,
            url: firstURL,
            title: "First article",
            canGoBack: true,
            canGoForward: false
        )

        store.addTab()
        let secondID = try XCTUnwrap(store.selectedTab?.id)
        let secondURL = try XCTUnwrap(URL(string: "https://second.example.com"))
        store.navigationFinished(
            for: secondID,
            url: secondURL,
            title: nil,
            canGoBack: false,
            canGoForward: true
        )

        let first = try XCTUnwrap(store.tabs.first(where: { $0.id == firstID }))
        let second = try XCTUnwrap(store.tabs.first(where: { $0.id == secondID }))
        XCTAssertEqual(first.currentURL, firstURL)
        XCTAssertEqual(first.displayTitle, "First article")
        XCTAssertTrue(first.canGoBack)
        XCTAssertEqual(second.currentURL, secondURL)
        XCTAssertEqual(second.displayTitle, "second.example.com")
        XCTAssertTrue(second.canGoForward)
    }

    func testClosingSelectedTabSelectsRemainingTabAndLateCallbackIsIgnored() throws {
        let store = BrowserTabStore()
        let firstID = try XCTUnwrap(store.selectedTab?.id)
        store.addTab()
        let secondID = try XCTUnwrap(store.selectedTab?.id)

        store.closeTab(secondID)
        XCTAssertEqual(store.selectedTabID, firstID)
        XCTAssertEqual(store.tabs.count, 1)

        store.closeTab(firstID)
        let replacementID = try XCTUnwrap(store.selectedTab?.id)
        XCTAssertNotEqual(replacementID, firstID)
        store.navigationFailed(NSError(domain: "late", code: 1), for: firstID)

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.selectedTabID, replacementID)
        XCTAssertNil(store.selectedErrorMessage)
        XCTAssertNil(store.selectedTab?.currentURL)
    }

    func testCancelledNavigationDoesNotShowAnError() throws {
        let store = BrowserTabStore()
        let id = try XCTUnwrap(store.selectedTab?.id)

        store.navigationStarted(for: id)
        store.navigationFailed(URLError(.cancelled), for: id)

        XCTAssertFalse(store.selectedIsLoading)
        XCTAssertNil(store.selectedErrorMessage)
    }
}
