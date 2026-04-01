import XCTest
@testable import Codex_Island

final class RemoteAppServerConnectionTests: XCTestCase {
    func testBackgroundThreadListTimeoutDoesNotEmitFailedState() async throws {
        let transport = TestTransport()
        let logger = TestDiagnosticsLogger()
        let recorder = RemoteEventRecorder()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)

        let connection = RemoteAppServerConnection(
            host: host,
            emit: { event in await recorder.append(event) },
            dependencies: RemoteAppServerConnectionDependencies(
                transportFactory: { _ in transport },
                processExecutor: TestProcessExecutor(),
                diagnosticsLogger: logger,
                requestTimeout: .milliseconds(50),
                refreshInterval: .seconds(60),
                sleep: { duration in
                    try await Task.sleep(for: duration)
                }
            )
        )

        try await connection.installTransportForTesting(transport)
        await connection.refreshThreadsInBackground(reason: "test")

        let states = await recorder.connectionStates()
        XCTAssertFalse(states.contains { if case .failed = $0 { return true } else { return false } })
        await connection.stop()
    }

    func testConcurrentRequestsMatchResponsesByID() async throws {
        let transport = TestTransport()
        let logger = TestDiagnosticsLogger()
        let recorder = RemoteEventRecorder()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)

        let connection = RemoteAppServerConnection(
            host: host,
            emit: { event in await recorder.append(event) },
            dependencies: RemoteAppServerConnectionDependencies(
                transportFactory: { _ in transport },
                processExecutor: TestProcessExecutor(),
                diagnosticsLogger: logger,
                requestTimeout: .seconds(1),
                refreshInterval: .seconds(60),
                sleep: { duration in
                    try await Task.sleep(for: duration)
                }
            )
        )

        try await connection.installTransportForTesting(transport)

        async let startedThread: RemoteAppServerThread = connection.startThread(defaultCwd: "/tmp")
        async let resumedThread: RemoteAppServerThread = connection.resumeThread(threadId: "thread-existing")

        try await waitUntil {
            let lines = await transport.sentLines
            return lines.contains { (try? Self.method(in: $0)) == "thread/start" } &&
                lines.contains { (try? Self.method(in: $0)) == "thread/resume" }
        }

        let sentLines = await transport.sentLines
        let startLine = try XCTUnwrap(sentLines.first(where: { (try? Self.method(in: $0)) == "thread/start" }))
        let resumeLine = try XCTUnwrap(sentLines.first(where: { (try? Self.method(in: $0)) == "thread/resume" }))
        let startID = try extractID(from: startLine)
        let resumeID = try extractID(from: resumeLine)

        try await transport.emitStdout(
            makeEnvelopeJSON(
                id: resumeID,
                result: ["thread": threadPayload(id: "thread-existing", preview: "Existing")]
            )
        )
        try await transport.emitStdout(
            makeEnvelopeJSON(
                id: startID,
                result: ["thread": threadPayload(id: "thread-new", preview: "New")]
            )
        )

        let started = try await startedThread
        let resumed = try await resumedThread

        XCTAssertEqual(started.id, "thread-new")
        XCTAssertEqual(resumed.id, "thread-existing")

        await connection.stop()
    }

    func testStopDoesNotEmitFailedState() async throws {
        let transport = TestTransport()
        let logger = TestDiagnosticsLogger()
        let recorder = RemoteEventRecorder()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)

        let connection = RemoteAppServerConnection(
            host: host,
            emit: { event in await recorder.append(event) },
            dependencies: RemoteAppServerConnectionDependencies(
                transportFactory: { _ in transport },
                processExecutor: TestProcessExecutor(),
                diagnosticsLogger: logger,
                requestTimeout: .seconds(1),
                refreshInterval: .seconds(60),
                sleep: { duration in
                    try await Task.sleep(for: duration)
                }
            )
        )

        try await connection.installTransportForTesting(transport)
        await connection.stop()
        let states = await recorder.connectionStates()
        XCTAssertFalse(states.contains { if case .failed = $0 { return true } else { return false } })
        let stopCount = await transport.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    private func extractID(from line: String) throws -> Int {
        let data = Data(line.utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["id"] as? Int)
    }

    private static func method(in line: String) throws -> String? {
        let data = Data(line.utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return object["method"] as? String
    }

    private func threadPayload(id: String, preview: String) -> [String: Any] {
        [
            "id": id,
            "preview": preview,
            "ephemeral": false,
            "modelProvider": "openai",
            "createdAt": 1_700_000_000,
            "updatedAt": 1_700_000_100,
            "status": ["type": "idle"],
            "path": NSNull(),
            "cwd": "/tmp",
            "cliVersion": "1.0.0",
            "name": NSNull(),
            "turns": []
        ]
    }
}
