import XCTest
@testable import Codex_Island

final class UniffiSharedEngineRuntimeDriverTests: XCTestCase {
    func testDriverMapsGeneratedStateAndQueuesHello() throws {
        let driver = UniffiSharedEngineRuntimeDriver(
            clientName: "Codex Island Tests",
            clientVersion: "0.0.0-test",
            authToken: "secret-token"
        )

        let initial = driver.currentState()
        XCTAssertEqual(initial.connection, .disconnected)
        XCTAssertEqual(initial.authToken, "secret-token")
        XCTAssertEqual(initial.snapshot.health.platform, .macos)

        let requested = try driver.send(.requestConnection)
        XCTAssertEqual(requested?.connection, .connecting)
        XCTAssertEqual(requested?.pendingCommands.first?.kind, .hello)
    }

    func testDriverApplyServerEventPromotesConnectedSnapshot() throws {
        let driver = UniffiSharedEngineRuntimeDriver(
            clientName: "Codex Island Tests",
            clientVersion: "0.0.0-test",
            authToken: nil
        )

        let applied = try driver.applyServerEvent(
            """
            {
              "type":"hello_ack",
              "protocol_version":"v1",
              "daemon_version":"0.1.0",
              "host_id":"host-123",
              "authenticated":true
            }
            """
        )

        XCTAssertEqual(applied.connection, .connected)
        XCTAssertTrue(applied.authenticated)
        XCTAssertEqual(applied.snapshot.health.hostID, "host-123")
        XCTAssertEqual(applied.snapshot.health.daemonVersion, "0.1.0")
    }

    func testDriverWrapsAppServerRequestIntent() throws {
        let driver = UniffiSharedEngineRuntimeDriver(
            clientName: "Codex Island Tests",
            clientVersion: "0.0.0-test",
            authToken: "secret-token"
        )

        let updated = try driver.send(.appServerRequest(
            requestId: "req-1",
            method: "thread/list",
            paramsJSON: #"{"limit":100}"#
        ))

        XCTAssertEqual(updated?.pendingCommands.last?.kind, .appServerRequest)
        XCTAssertTrue(updated?.pendingCommands.last?.commandJSON.contains("\"thread/list\"") == true)
    }
}
