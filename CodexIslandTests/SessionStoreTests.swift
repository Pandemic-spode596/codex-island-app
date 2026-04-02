import XCTest
@testable import Codex_Island

actor SessionStoreTestHelper {
    static let shared = SessionStoreTestHelper()

    func cleanup() async {
        let sessions = await SessionStore.shared.allSessions()
        for session in sessions {
            await SessionStore.shared.process(.sessionEnded(sessionId: session.sessionId))
        }
    }
}

final class SessionStoreTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await SessionStoreTestHelper.shared.cleanup()
    }

    override func tearDown() async throws {
        await SessionStoreTestHelper.shared.cleanup()
        try await super.tearDown()
    }

    func testSameTTYRebindsToLatestSession() async {
        let first = makeHookEvent(sessionId: "session-1", tty: "/dev/ttys001")
        let second = makeHookEvent(sessionId: "session-2", tty: "/dev/ttys001")

        await SessionStore.shared.process(.hookReceived(first))
        let firstLogicalId = await SessionStore.shared.allSessions().first?.logicalSessionId

        await SessionStore.shared.process(.hookReceived(second))
        let sessions = await SessionStore.shared.allSessions()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.sessionId, "session-2")
        XCTAssertEqual(sessions.first?.logicalSessionId, firstLogicalId)
    }

    func testDifferentTTYsRemainSeparateSessions() async {
        await SessionStore.shared.process(.hookReceived(makeHookEvent(sessionId: "session-1", tty: "/dev/ttys001")))
        await SessionStore.shared.process(.hookReceived(makeHookEvent(sessionId: "session-2", tty: "/dev/ttys002")))

        let sessions = await SessionStore.shared.allSessions()

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(Set(sessions.map(\.sessionId)), ["session-1", "session-2"])
        XCTAssertEqual(Set(sessions.map(\.logicalSessionId)).count, 2)
    }

    private func makeHookEvent(sessionId: String, tty: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            provider: .codex,
            cwd: "/tmp/project",
            transcriptPath: nil,
            event: "SessionStart",
            status: "waiting_for_input",
            pid: nil,
            tty: tty,
            terminalName: "Apple_Terminal",
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
}
