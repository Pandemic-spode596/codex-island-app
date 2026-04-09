import XCTest
@testable import Codex_Island

@MainActor
final class SharedEngineRemoteSessionBackendTests: XCTestCase {
    func testStartMonitoringRequestsConnectionAndProjectsThread() {
        let runtime = FakeSharedEngineRuntimeDriver(
            state: Self.makeRuntimeState(connection: .disconnected, activeThreadID: "thread-1")
        )
        let backend = SharedEngineRemoteSessionBackend(
            host: RemoteHostConfig(
                id: "host-1",
                name: "Local Engine",
                sshTarget: "local-app-server",
                defaultCwd: "/repo",
                isEnabled: true
            ),
            runtime: runtime
        )

        backend.startMonitoring()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(runtime.sentIntents, [.requestConnection, .getSnapshot])
        XCTAssertEqual(backend.hostStates["host-1"], .connecting)
        XCTAssertEqual(backend.threads.map(\.threadId), ["thread-1"])
    }

    func testSendMessageUsesTurnSteerWhenThreadCanSteer() async throws {
        let runtime = FakeSharedEngineRuntimeDriver(
            state: Self.makeRuntimeState(connection: .connected, activeThreadID: "thread-1", activeTurnID: "turn-1")
        )
        let backend = SharedEngineRemoteSessionBackend(
            host: RemoteHostConfig(
                id: "host-1",
                name: "Local Engine",
                sshTarget: "local-app-server",
                defaultCwd: "/repo",
                isEnabled: true
            ),
            runtime: runtime
        )
        let thread = try XCTUnwrap(backend.threads.first)

        try await backend.sendMessage(thread: thread, text: "continue")

        guard case .appServerRequest(_, let method, let paramsJSON)? = runtime.sentIntents.last else {
            return XCTFail("Expected app server request intent")
        }
        XCTAssertEqual(method, "turn/steer")
        XCTAssertTrue(paramsJSON.contains("\"expectedTurnId\":\"turn-1\""))
        XCTAssertTrue(backend.threads.first?.history.last?.type == .assistant("Queued via shared engine: continue"))
    }

    func testApplyServerEventUpdatesProjectedState() throws {
        let runtime = FakeSharedEngineRuntimeDriver(
            state: Self.makeRuntimeState(connection: .connecting)
        )
        let backend = SharedEngineRemoteSessionBackend(
            host: RemoteHostConfig(
                id: "host-1",
                name: "Local Engine",
                sshTarget: "local-app-server",
                defaultCwd: "/repo",
                isEnabled: true
            ),
            runtime: runtime
        )

        runtime.nextAppliedState = Self.makeRuntimeState(connection: .connected, activeThreadID: "thread-9")
        try backend.applyServerEventJSON("{\"type\":\"snapshot\"}")

        XCTAssertEqual(backend.hostStates["host-1"], .connected)
        XCTAssertEqual(backend.threads.first?.threadId, "thread-9")
    }

    private static func makeRuntimeState(
        connection: SharedEngineConnectionState,
        activeThreadID: String? = nil,
        activeTurnID: String? = nil
    ) -> SharedEngineRuntimeState {
        SharedEngineRuntimeState(
            connection: connection,
            snapshot: SharedEngineSnapshot(
                health: SharedEngineHostHealth(
                    protocolVersion: "v1",
                    daemonVersion: "0.1.0",
                    hostID: "host-1",
                    hostname: "devbox",
                    platform: .macos,
                    status: .ready,
                    startedAt: "2026-04-09T00:00:00Z",
                    observedAt: "2026-04-09T00:00:01Z",
                    appServer: SharedEngineAppServerHealth(
                        state: .ready,
                        launchCommand: ["codex", "app-server"],
                        cwd: "/repo",
                        pid: 42,
                        lastExitCode: nil,
                        lastError: nil,
                        restartCount: 0
                    ),
                    capabilities: SharedEngineCapabilities(
                        pairing: true,
                        appServerBridge: true,
                        transcriptFallback: true,
                        reconnectResume: true
                    ),
                    pairedDeviceCount: 0
                ),
                activePairing: nil,
                pairedDevices: [],
                activeThreadID: activeThreadID,
                activeTurnID: activeTurnID
            ),
            authenticated: true,
            authToken: "token-1",
            lastErrorMessage: nil,
            lastAppServerEventJSON: nil,
            pendingCommands: [],
            inFlightCommand: nil,
            reconnect: SharedEngineReconnectState(
                shouldReconnect: false,
                reconnectPending: false,
                attemptCount: 0,
                currentBackoffMs: 0,
                nextBackoffMs: nil,
                lastScheduledAtMs: nil,
                lastReconnectedAtMs: nil,
                lastDisconnectReason: nil
            ),
            diagnostics: SharedEngineDiagnostics(
                connectAttempts: 1,
                successfulConnects: 1,
                disconnectCount: 0,
                authFailures: 0,
                protocolErrorCount: 0,
                transportErrorCount: 0,
                lastErrorMessage: nil,
                lastResponseRequestID: nil
            )
        )
    }
}

private final class FakeSharedEngineRuntimeDriver: @unchecked Sendable, SharedEngineRuntimeDriving {
    var sentIntents: [EngineShellCommandIntent] = []
    var state: SharedEngineRuntimeState
    var nextAppliedState: SharedEngineRuntimeState?

    init(state: SharedEngineRuntimeState) {
        self.state = state
    }

    func currentState() -> SharedEngineRuntimeState {
        state
    }

    func applyServerEvent(_ eventJSON: String) throws -> SharedEngineRuntimeState {
        if let nextAppliedState {
            state = nextAppliedState
        }
        return state
    }

    func send(_ intent: EngineShellCommandIntent) throws -> SharedEngineRuntimeState? {
        sentIntents.append(intent)
        switch intent {
        case .requestConnection:
            state = SharedEngineRuntimeState(
                connection: .connecting,
                snapshot: state.snapshot,
                authenticated: state.authenticated,
                authToken: state.authToken,
                lastErrorMessage: state.lastErrorMessage,
                lastAppServerEventJSON: state.lastAppServerEventJSON,
                pendingCommands: state.pendingCommands,
                inFlightCommand: state.inFlightCommand,
                reconnect: state.reconnect,
                diagnostics: state.diagnostics
            )
        default:
            break
        }
        return state
    }

    func popNextCommandJSON() -> String? {
        nil
    }
}
