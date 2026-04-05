import XCTest
import Markdown
@testable import Codex_Island

@MainActor
final class ChatHistoryManagerTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await SessionStoreTestHelper.shared.cleanup()
        ChatHistoryManager.shared.resetForTesting()
    }

    override func tearDown() async throws {
        ChatHistoryManager.shared.resetForTesting()
        await SessionStoreTestHelper.shared.cleanup()
        try await super.tearDown()
    }

    func testSessionWithoutTranscriptIsNotMarkedLoadedAfterExplicitHistoryLoad() async {
        await SessionStore.shared.process(.hookReceived(makeHookEvent(sessionId: "session-1", tty: "/dev/ttys001")))
        await Task.yield()

        guard let session = await SessionStore.shared.allSessions().first else {
            return XCTFail("Expected session")
        }

        XCTAssertFalse(
            ChatHistoryManager.shared.isLoaded(
                logicalSessionId: session.logicalSessionId,
                sessionId: session.sessionId
            )
        )

        await ChatHistoryManager.shared.loadFromFile(
            logicalSessionId: session.logicalSessionId,
            sessionId: session.sessionId,
            cwd: session.cwd
        )

        XCTAssertFalse(
            ChatHistoryManager.shared.isLoaded(
                logicalSessionId: session.logicalSessionId,
                sessionId: session.sessionId
            )
        )
    }

    func testSessionWithTranscriptCanBeMarkedLoadedEvenWhenConversationIsEmpty() async throws {
        let transcriptPath = try makeTempTranscriptFile()
        await SessionStore.shared.process(.hookReceived(
            makeHookEvent(
                sessionId: "session-1",
                tty: "/dev/ttys001",
                transcriptPath: transcriptPath
            )
        ))
        await Task.yield()

        guard let session = await SessionStore.shared.allSessions().first else {
            return XCTFail("Expected session")
        }

        await ChatHistoryManager.shared.loadFromFile(
            logicalSessionId: session.logicalSessionId,
            sessionId: session.sessionId,
            cwd: session.cwd
        )

        XCTAssertTrue(
            ChatHistoryManager.shared.isLoaded(
                logicalSessionId: session.logicalSessionId,
                sessionId: session.sessionId
            )
        )
    }

    func testReboundLogicalSessionRequiresReloadForLatestSessionId() async throws {
        let transcriptPath = try makeTempTranscriptFile()
        await SessionStore.shared.process(.hookReceived(
            makeHookEvent(
                sessionId: "session-1",
                tty: "/dev/ttys001",
                transcriptPath: transcriptPath
            )
        ))

        guard let firstSession = await SessionStore.shared.allSessions().first else {
            return XCTFail("Expected first session")
        }

        await ChatHistoryManager.shared.loadFromFile(
            logicalSessionId: firstSession.logicalSessionId,
            sessionId: firstSession.sessionId,
            cwd: firstSession.cwd
        )

        XCTAssertTrue(
            ChatHistoryManager.shared.isLoaded(
                logicalSessionId: firstSession.logicalSessionId,
                sessionId: firstSession.sessionId
            )
        )

        await SessionStore.shared.process(.hookReceived(makeHookEvent(sessionId: "session-2", tty: "/dev/ttys001")))
        await Task.yield()

        guard let reboundSession = await SessionStore.shared.allSessions().first else {
            return XCTFail("Expected rebound session")
        }

        XCTAssertEqual(reboundSession.sessionId, "session-2")
        XCTAssertEqual(reboundSession.logicalSessionId, firstSession.logicalSessionId)
        XCTAssertFalse(
            ChatHistoryManager.shared.isLoaded(
                logicalSessionId: reboundSession.logicalSessionId,
                sessionId: reboundSession.sessionId
            )
        )
    }

    func testMarkdownListRendererSkipsEmptyListItems() throws {
        let document = Document(parsing: "- \n- 第一条\n-\n- 第二条")
        let list = try XCTUnwrap(Array(document.children).first as? UnorderedList)

        let renderableCounts = Array(list.listItems.map { item in
            MarkdownListItemRenderer.renderableChildren(for: item).count
        })

        XCTAssertEqual(renderableCounts, [0, 1, 0, 1])
        XCTAssertEqual(renderableCounts.filter { $0 > 0 }.count, 2)
    }

    func testErrorToolCallUsesFailureDisplayTextForCommand() {
        let item = ToolCallItem(
            name: "Command",
            input: ["command": "false"],
            status: .error,
            result: "exit code 1",
            structuredResult: nil,
            subagentTools: []
        )

        XCTAssertEqual(item.statusDisplay.text, "Command failed")
        XCTAssertFalse(item.statusDisplay.isRunning)
    }

    private func makeHookEvent(
        sessionId: String,
        tty: String?,
        pid: Int? = nil,
        cwd: String = "/tmp/project",
        terminalName: String = "Apple_Terminal",
        transcriptPath: String? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            provider: .codex,
            cwd: cwd,
            transcriptPath: transcriptPath,
            event: "SessionStart",
            status: "waiting_for_input",
            pid: pid,
            tty: tty,
            terminalName: terminalName,
            terminalWindowId: nil,
            terminalTabId: nil,
            terminalSurfaceId: nil,
            turnId: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil
        )
    }

    private func makeTempTranscriptFile() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jsonl")
        try Data().write(to: path)
        return path.path
    }
}
