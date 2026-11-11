import XCTest

/// Drives the app in demo mode (`-demo`): sample content, a scripted model and a canned SSH host,
/// so every flow runs end to end without a network.
final class TermAIUITests: XCTestCase {
    private var app: XCUIApplication!
    /// Generous: the simulator on CI is slow.
    private let patience: TimeInterval = 45

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: Helpers

    private func launch(_ arguments: String...) {
        app.launchArguments = ["-demo"] + arguments
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func elements(_ identifier: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: identifier)
    }

    private func text(_ label: String) -> XCUIElement {
        app.staticTexts[label].firstMatch
    }

    private func text(containing fragment: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    private func button(startingWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func assertExists(_ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        if !element.waitForExistence(timeout: patience) {
            XCTFail("\(what) did not appear.\n\(app.debugDescription)", file: file, line: line)
        }
    }

    private func assertGone(_ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        if XCTWaiter().wait(for: [gone], timeout: patience) != .completed {
            XCTFail("\(what) is still on screen.\n\(app.debugDescription)", file: file, line: line)
        }
    }

    private func assertCount(_ query: XCUIElementQuery, _ count: Int, _ what: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", count), object: query)
        if XCTWaiter().wait(for: [settled], timeout: patience) != .completed {
            XCTFail("expected \(count) \(what), found \(query.count).\n\(app.debugDescription)", file: file, line: line)
        }
    }

    private func tap(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = element(identifier)
        assertExists(target, identifier, file: file, line: line)
        target.tap()
    }

    private func type(_ string: String, into identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = element(identifier)
        assertExists(field, identifier, file: file, line: line)
        field.tap()
        field.typeText(string)
    }

    // MARK: Sidebar and sessions

    func testSidebarSwitchesSessionsAndHasNoCustomize() {
        launch()
        assertExists(text("Fixed. nginx is serving again."), "the demo conversation")
        XCTAssertEqual(element("session-title").label, "Why is nginx down on web1?")

        tap("topbar-sidebar")
        assertExists(text("Recents"), "the sidebar")
        for item in ["sidebar-new", "sidebar-search", "sidebar-files", "sidebar-terminal", "sidebar-settings"] {
            XCTAssertTrue(element(item).exists, "\(item) is missing from the sidebar")
        }
        let customize = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "customize"))
        XCTAssertEqual(customize.count, 0, "Customize should be gone from the sidebar")
        assertCount(elements("recent-session"), 4, "recent sessions")

        // Tapping a recent session opens it and closes the sidebar.
        button(startingWith: "Rotate the deploy keys").tap()
        assertGone(text("Recents"), "the sidebar")
        assertExists(text("Done on web1."), "the other session's conversation")
        XCTAssertEqual(element("session-title").label, "Rotate the deploy keys")

        // And back again: the first session was saved and reopens as it was.
        tap("topbar-sidebar")
        assertExists(text("Recents"), "the sidebar")
        button(startingWith: "Why is nginx down on web1?").tap()
        assertExists(text("Fixed. nginx is serving again."), "the first session's conversation")

        tap("topbar-sidebar")
        tap("sidebar-new")
        assertExists(text("Ready when you are"), "the empty session")
        XCTAssertEqual(element("session-title").label, "New session")
    }

    func testSearchFindsASessionByWhatWasSaidInIt() {
        launch()
        tap("topbar-sidebar")
        tap("sidebar-search")
        assertExists(app.navigationBars["Search"], "the search sheet")
        assertCount(elements("search-result"), 4, "sessions listed before searching")

        let field = app.searchFields.firstMatch
        assertExists(field, "the search field")
        field.tap()
        field.typeText("deploy")
        assertCount(elements("search-result"), 1, "search results")

        tap("search-result")
        assertExists(text("Done on web1."), "the found session's conversation")
        XCTAssertEqual(element("session-title").label, "Rotate the deploy keys")
    }

    // MARK: Files

    func testSelectedFilesAreAttachedWhenDoneIsPressed() {
        launch()
        tap("topbar-files")
        assertExists(app.navigationBars["Files"], "the files sheet")

        tap("file-report.md")
        tap("file-notes")
        tap("file-notes/todo.md")
        tap("files-done")

        assertExists(element("attachment-report.md"), "report.md in the message box")
        assertExists(element("attachment-todo.md"), "todo.md in the message box")
        assertGone(app.navigationBars["Files"], "the files sheet")
    }

    func testFilePreviewAndFilter() {
        launch("-demoEmpty")
        tap("empty-files")
        assertExists(app.navigationBars["Files"], "the files sheet")

        type("nginx", into: "files-filter")
        assertExists(element("file-nginx-app.conf"), "the filtered file")
        assertGone(element("file-report.md"), "a file the filter should hide")

        tap("preview-nginx-app.conf")
        assertExists(text(containing: "server_name example.com;"), "the file's contents")
        tap("viewer-select")
        tap("files-attach")
        assertExists(element("attachment-nginx-app.conf"), "nginx-app.conf in the message box")
    }

    // MARK: Conversation

    func testSendingAPromptRunsToolsWithApproval() {
        launch("-demoEmpty")
        assertExists(text("Ready when you are"), "the empty session")

        type("why is nginx down on web1?", into: "composer-input")
        tap("composer-send")

        // Each command waits for an answer before it runs.
        assertExists(text("Allow this action?"), "the first approval request")
        tap("approval-allow")
        assertExists(text(containing: "typo"), "the diagnosis")
        assertExists(text("Allow this action?"), "the second approval request")
        tap("approval-allow")
        assertExists(text("Fixed. nginx is serving again."), "the final answer")
        assertExists(text(containing: "2.4k in"), "the usage line")
        assertCount(elements("tool-row"), 2, "tool steps")

        // The session is named after the prompt.
        XCTAssertEqual(element("session-title").label, "Why is nginx down on web1?")
    }

    func testDenyingAnActionAndStoppingTheRun() {
        launch("-demoEmpty")
        type("why is nginx down on web1?", into: "composer-input")
        tap("composer-send")
        assertExists(text("Allow this action?"), "the approval request")
        tap("approval-deny")
        // The model is told about the refusal and carries on, so its next request arrives.
        assertExists(text(containing: "typo"), "the model's next message")
        assertExists(text("Allow this action?"), "the next approval request")

        XCTAssertEqual(element("composer-send").label, "Stop")
        tap("composer-send")
        assertExists(text("stopped"), "the stop notice")
        assertGone(text("Allow this action?"), "the approval card")
        XCTAssertEqual(element("composer-send").label, "Send")
    }

    func testToolStepsStayFoldedUntilTapped() {
        launch()
        assertExists(text("Fixed. nginx is serving again."), "the demo conversation")
        XCTAssertFalse(element("tool-output").exists, "tool output should start folded")

        elements("tool-row").firstMatch.tap()
        assertExists(element("tool-output"), "the unfolded tool output")
        XCTAssertTrue(element("tool-output").label.contains("Active: failed"), element("tool-output").label)

        elements("tool-row").firstMatch.tap()
        assertGone(element("tool-output"), "the folded tool output")
    }

    func testLongToolListsShowTheNewestStepsUntilUnfolded() {
        launch("-demoSteps")
        assertExists(element("tool-group-toggle"), "the list header")
        assertCount(elements("tool-row"), 3, "tool steps while folded")
        tap("tool-group-toggle")
        assertCount(elements("tool-row"), 7, "tool steps once unfolded")
    }

    func testEditingAMessageReplacesItAndItsReplies() {
        launch()
        assertExists(text("Fixed. nginx is serving again."), "the demo conversation")

        tap("edit-last-prompt")
        assertExists(element("editing-banner"), "the editing banner")
        let input = element("composer-input")
        XCTAssertEqual(input.value as? String, "why is nginx down on web1?")

        // Tap at the end of the text so the addition lands after it.
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        input.typeText(" check again")
        tap("composer-send")

        assertExists(text(containing: "check again"), "the edited message")
        assertGone(text("Fixed. nginx is serving again."), "the old answer")
        assertGone(element("editing-banner"), "the editing banner")
        // The edited message starts a fresh run.
        assertExists(text("Allow this action?"), "the approval request of the new run")
    }

    // MARK: Terminal, models, settings

    func testTerminalRunsCommandsOutsideTheChat() {
        launch()
        tap("topbar-terminal")
        assertExists(app.navigationBars["Terminal"], "the terminal sheet")
        assertExists(text(containing: "stay out of the chat"), "the terminal's explanation")

        type("uptime", into: "terminal-input")
        tap("terminal-run")
        assertExists(text(containing: "up 41 days"), "the command's output")

        tap("terminal-clear")
        assertGone(text(containing: "up 41 days"), "the cleared output")

        tap("terminal-done")
        assertGone(app.navigationBars["Terminal"], "the terminal sheet")
        // Nothing from the terminal reached the conversation.
        XCTAssertFalse(text(containing: "up 41 days").exists)
        assertExists(text("Fixed. nginx is serving again."), "the conversation")
    }

    func testModelPickerSwitchesTheModel() {
        launch()
        assertExists(element("composer-model"), "the model button")
        XCTAssertEqual(element("composer-model").label, "Model: claude-sonnet-5")

        tap("composer-model")
        assertExists(app.navigationBars["Models"], "the model picker")
        app.buttons["openai/gpt-6-luna"].firstMatch.tap()
        assertGone(app.navigationBars["Models"], "the model picker")
        XCTAssertEqual(element("composer-model").label, "Model: gpt-6-luna")
    }

    func testSettingsOpensAConnectionAndTestsIt() {
        launch()
        tap("topbar-sidebar")
        tap("sidebar-settings")
        assertExists(app.navigationBars["Settings"], "settings")

        // The sidebar's connection menu also starts with the name; this is the row in the settings list.
        app.collectionViews.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "openrouter")).firstMatch.tap()
        assertExists(text("Connection"), "the connection editor")
        XCTAssertTrue(text("Custom headers").exists, "the custom headers section")

        tap("connection-test")
        assertExists(text("Connected · 2 models available"), "the connection test result")

        app.buttons["Cancel"].firstMatch.tap()
        assertExists(element("settings-add-host"), "the settings list")
        app.buttons["Done"].firstMatch.tap()
        assertGone(app.navigationBars["Settings"], "settings")
    }
}
