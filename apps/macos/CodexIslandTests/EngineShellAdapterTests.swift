import XCTest
@testable import Codex_Island

final class EngineShellAdapterTests: XCTestCase {
    func testCommandAdapterDelegatesIntentsToInjectedSender() throws {
        let recordedIntent = LockedValueBox<EngineShellCommandIntent?>(nil)
        let adapter = EngineRuntimeCommandAdapter(
            stateProvider: {
                Self.makeRuntimeState(connection: .disconnected, authenticated: false)
            },
            eventApplier: { _ in
                Self.makeRuntimeState(connection: .connected, authenticated: true)
            },
            sender: { intent in
                recordedIntent.set(intent)
                return Self.makeRuntimeState(connection: .connecting, authenticated: false)
            }
        )

        let returned = try adapter.send(.pairStart(deviceName: "Pixel", clientPlatform: "android"))

        XCTAssertEqual(recordedIntent.get(), .pairStart(deviceName: "Pixel", clientPlatform: "android"))
        XCTAssertEqual(returned?.connection, .connecting)
    }

    func testHostAdapterProjectsRuntimeStateIntoUiFacingSummary() {
        let state = Self.makeRuntimeState(
            connection: .connected,
            authenticated: true,
            activeThreadID: "thread-1",
            activeTurnID: "turn-9",
            activePairingCode: "123-456",
            pendingCommands: [
                SharedEngineQueuedCommand(
                    queueID: 7,
                    kind: .appServerRequest,
                    commandJSON: "{}",
                    enqueuedAtMs: 1,
                    lastSentAtMs: nil,
                    attemptCount: 0
                )
            ]
        )

        let projected = EngineHostAdapterState(runtimeState: state, preferredHostName: "Island Host")

        XCTAssertEqual(projected.hostID, "host-1")
        XCTAssertEqual(projected.hostName, "Island Host")
        XCTAssertTrue(projected.authenticated)
        XCTAssertEqual(projected.activeThreadID, "thread-1")
        XCTAssertEqual(projected.activeTurnID, "turn-9")
        XCTAssertEqual(projected.activePairingCode, "123-456")
        XCTAssertEqual(projected.connectionState, .connected)
        XCTAssertEqual(projected.appServerState, "ready")
        XCTAssertEqual(projected.reconnectSummary, "idle")
        XCTAssertEqual(projected.queueSummary, "1 pending / in-flight none")
    }

    func testThreadAdapterBuildsRemoteThreadPlaceholder() throws {
        let state = Self.makeRuntimeState(
            connection: .connected,
            authenticated: true,
            activeThreadID: "thread-1",
            activeTurnID: "turn-2",
            inFlightCommand: SharedEngineQueuedCommand(
                queueID: 9,
                kind: .appServerRequest,
                commandJSON: "{}",
                enqueuedAtMs: 1,
                lastSentAtMs: 2,
                attemptCount: 1
            )
        )

        let adapterState = try XCTUnwrap(
            EngineThreadAdapterState(
                runtimeState: state,
                preferredHostName: "Remote Mac",
                cwd: "/repo"
            )
        )
        let remoteThread = adapterState.makeRemoteThreadState(now: Date(timeIntervalSince1970: 123))

        XCTAssertEqual(remoteThread.hostId, "host-1")
        XCTAssertEqual(remoteThread.hostName, "Remote Mac")
        XCTAssertEqual(remoteThread.threadId, "thread-1")
        XCTAssertEqual(remoteThread.logicalSessionId, "engine-host-1-thread-1")
        XCTAssertEqual(remoteThread.cwd, "/repo")
        XCTAssertEqual(remoteThread.phase, .processing)
        XCTAssertEqual(remoteThread.connectionState, .connected)
        XCTAssertEqual(remoteThread.activeTurnId, "turn-2")
        XCTAssertFalse(remoteThread.isLoaded)
        XCTAssertTrue(remoteThread.canSteerTurn)
    }

    private static func makeRuntimeState(
        connection: SharedEngineConnectionState,
        authenticated: Bool,
        activeThreadID: String? = nil,
        activeTurnID: String? = nil,
        activePairingCode: String? = nil,
        pendingCommands: [SharedEngineQueuedCommand] = [],
        inFlightCommand: SharedEngineQueuedCommand? = nil
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
                        pid: 123,
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
                    pairedDeviceCount: 1
                ),
                activePairing: activePairingCode.map {
                    SharedEnginePairingSession(
                        pairingCode: $0,
                        sessionID: "pair-1",
                        deviceName: "iPhone",
                        expiresAt: "2026-04-09T00:10:00Z"
                    )
                },
                pairedDevices: [
                    SharedEnginePairedDevice(
                        deviceID: "device-1",
                        deviceName: "Android",
                        platform: "android",
                        createdAt: "2026-04-09T00:00:00Z",
                        lastSeenAt: nil,
                        lastIP: nil
                    )
                ],
                activeThreadID: activeThreadID,
                activeTurnID: activeTurnID
            ),
            authenticated: authenticated,
            authToken: authenticated ? "token-1" : nil,
            lastErrorMessage: nil,
            lastAppServerEventJSON: nil,
            pendingCommands: pendingCommands,
            inFlightCommand: inFlightCommand,
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
