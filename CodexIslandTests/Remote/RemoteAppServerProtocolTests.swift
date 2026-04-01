import XCTest
@testable import Codex_Island

final class RemoteAppServerProtocolTests: XCTestCase {
    func testDecodeActiveThreadStatus() throws {
        let data = #"{"type":"active","activeFlags":["waitingOnUserInput"]}"#.data(using: .utf8)!
        let status = try JSONDecoder().decode(RemoteAppServerThreadStatus.self, from: data)

        XCTAssertEqual(status, .active(activeFlags: [.waitingOnUserInput]))
    }

    func testDecodeUnknownUserInputFallsBackToUnsupported() throws {
        let data = #"{"type":"audio","url":"https://example.com"}"#.data(using: .utf8)!
        let input = try JSONDecoder().decode(RemoteAppServerUserInput.self, from: data)

        XCTAssertEqual(input, .unsupported)
        XCTAssertNil(input.displayText)
    }

    func testDecodeCommandExecutionItem() throws {
        let data = #"""
        {
          "type":"commandExecution",
          "id":"cmd-1",
          "command":"pwd",
          "cwd":"/tmp",
          "status":"completed",
          "aggregatedOutput":"/tmp"
        }
        """#.data(using: .utf8)!
        let item = try JSONDecoder().decode(RemoteAppServerThreadItem.self, from: data)

        XCTAssertEqual(
            item,
            .commandExecution(
                id: "cmd-1",
                command: "pwd",
                cwd: "/tmp",
                status: .completed,
                aggregatedOutput: "/tmp"
            )
        )
    }

    func testDecodeErrorNotificationAdditionalDetails() throws {
        let data = #"""
        {
          "error": {
            "message": "403 Forbidden",
            "additionalDetails": "Usage not included in your plan"
          },
          "willRetry": false,
          "threadId": "thread-1",
          "turnId": "turn-1"
        }
        """#.data(using: .utf8)!
        let notification = try JSONDecoder().decode(RemoteAppServerErrorNotification.self, from: data)

        XCTAssertEqual(notification.threadId, "thread-1")
        XCTAssertEqual(notification.turnId, "turn-1")
        XCTAssertEqual(notification.error.additionalDetails, "Usage not included in your plan")
        XCTAssertFalse(notification.willRetry)
    }
}
