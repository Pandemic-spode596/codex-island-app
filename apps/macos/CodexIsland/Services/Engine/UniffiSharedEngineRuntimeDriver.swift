//
//  UniffiSharedEngineRuntimeDriver.swift
//  CodexIsland
//
//  Real SharedEngineRuntimeDriving implementation backed by generated UniFFI bindings.
//

import Foundation

final class UniffiSharedEngineRuntimeDriver: SharedEngineRuntimeDriving, @unchecked Sendable {
    private let runtime: any EngineRuntimeProtocol

    init(runtime: any EngineRuntimeProtocol) {
        self.runtime = runtime
    }

    convenience init(
        clientName: String,
        clientVersion: String,
        authToken: String?
    ) {
        self.init(runtime: EngineRuntime(config: ClientRuntimeConfig(
            clientName: clientName,
            clientVersion: clientVersion,
            authToken: authToken
        )))
    }

    func currentState() -> SharedEngineRuntimeState {
        runtime.state().sharedEngineState
    }

    func applyServerEvent(_ eventJSON: String) throws -> SharedEngineRuntimeState {
        try runtime.applyServerEventJson(eventJson: eventJSON).sharedEngineState
    }

    func popNextCommandJSON() -> String? {
        runtime.popNextCommandJson()
    }

    @discardableResult
    func send(_ intent: EngineShellCommandIntent) throws -> SharedEngineRuntimeState? {
        switch intent {
        case .requestConnection:
            return runtime.requestConnection().sharedEngineState
        case .activateReconnectNow:
            _ = runtime.activateReconnectNow()
            return runtime.state().sharedEngineState
        case .getSnapshot:
            _ = runtime.enqueueGetSnapshot()
            return runtime.state().sharedEngineState
        case .pairStart(let deviceName, let clientPlatform):
            _ = runtime.enqueuePairStart(deviceName: deviceName, clientPlatform: clientPlatform)
            return runtime.state().sharedEngineState
        case .pairConfirm(let pairingCode, let deviceName, let clientPlatform):
            _ = runtime.enqueuePairConfirm(
                pairingCode: pairingCode,
                deviceName: deviceName,
                clientPlatform: clientPlatform
            )
            return runtime.state().sharedEngineState
        case .pairRevoke(let deviceId):
            _ = runtime.enqueuePairRevoke(deviceId: deviceId)
            return runtime.state().sharedEngineState
        case .appServerRequest(let requestId, let method, let paramsJSON):
            _ = try runtime.enqueueAppServerRequest(
                requestId: requestId,
                method: method,
                paramsJson: paramsJSON
            )
            return runtime.state().sharedEngineState
        case .appServerResponse(let requestId, let resultJSON):
            _ = try runtime.enqueueAppServerResponse(
                requestId: requestId,
                resultJson: resultJSON
            )
            return runtime.state().sharedEngineState
        case .appServerInterrupt(let threadId, let turnId):
            _ = runtime.enqueueAppServerInterrupt(threadId: threadId, turnId: turnId)
            return runtime.state().sharedEngineState
        case .transportDisconnected(let reason):
            return runtime.transportDisconnected(reason: reason).sharedEngineState
        case .replaceAuthToken(let token):
            runtime.replaceAuthToken(authToken: token)
            return runtime.state().sharedEngineState
        case .setShouldReconnect(let shouldReconnect):
            runtime.setShouldReconnect(shouldReconnect: shouldReconnect)
            return runtime.state().sharedEngineState
        }
    }
}

private extension EngineRuntimeState {
    var sharedEngineState: SharedEngineRuntimeState {
        SharedEngineRuntimeState(
            connection: connection.sharedEngineConnectionState,
            snapshot: snapshot.sharedEngineSnapshot,
            authenticated: authenticated,
            authToken: authToken,
            lastErrorMessage: lastError?.message,
            lastAppServerEventJSON: lastAppServerEventJson,
            pendingCommands: pendingCommands.map(\.sharedEngineQueuedCommand),
            inFlightCommand: inFlightCommand?.sharedEngineQueuedCommand,
            reconnect: reconnect.sharedEngineReconnectState,
            diagnostics: diagnostics.sharedEngineDiagnostics
        )
    }
}

private extension EngineSnapshotRecord {
    var sharedEngineSnapshot: SharedEngineSnapshot {
        SharedEngineSnapshot(
            health: health.sharedEngineHostHealth,
            activePairing: activePairing?.sharedEnginePairingSession,
            pairedDevices: pairedDevices.map(\.sharedEnginePairedDevice),
            activeThreadID: activeThreadId,
            activeTurnID: activeTurnId
        )
    }
}

private extension HostHealthSnapshot {
    var sharedEngineHostHealth: SharedEngineHostHealth {
        SharedEngineHostHealth(
            protocolVersion: protocolVersion,
            daemonVersion: daemonVersion,
            hostID: hostId,
            hostname: hostname,
            platform: platform.sharedEngineHostPlatform,
            status: status.sharedEngineHostHealthStatus,
            startedAt: startedAt,
            observedAt: observedAt,
            appServer: appServer.sharedEngineAppServerHealth,
            capabilities: capabilities.sharedEngineCapabilities,
            pairedDeviceCount: pairedDeviceCount
        )
    }
}

private extension AppServerHealth {
    var sharedEngineAppServerHealth: SharedEngineAppServerHealth {
        SharedEngineAppServerHealth(
            state: state.sharedEngineAppServerState,
            launchCommand: launchCommand,
            cwd: cwd,
            pid: pid,
            lastExitCode: lastExitCode,
            lastError: lastError,
            restartCount: restartCount
        )
    }
}

private extension HostCapabilities {
    var sharedEngineCapabilities: SharedEngineCapabilities {
        SharedEngineCapabilities(
            pairing: pairing,
            appServerBridge: appServerBridge,
            transcriptFallback: transcriptFallback,
            reconnectResume: reconnectResume
        )
    }
}

private extension PairingSession {
    var sharedEnginePairingSession: SharedEnginePairingSession {
        SharedEnginePairingSession(
            pairingCode: pairingCode,
            sessionID: sessionId,
            deviceName: deviceName,
            expiresAt: expiresAt
        )
    }
}

private extension PairedDeviceRecord {
    var sharedEnginePairedDevice: SharedEnginePairedDevice {
        SharedEnginePairedDevice(
            deviceID: deviceId,
            deviceName: deviceName,
            platform: platform,
            createdAt: createdAt,
            lastSeenAt: lastSeenAt,
            lastIP: lastIp
        )
    }
}

private extension QueuedCommandRecord {
    var sharedEngineQueuedCommand: SharedEngineQueuedCommand {
        SharedEngineQueuedCommand(
            queueID: queueId,
            kind: kind.sharedEngineCommandKind,
            commandJSON: commandJson,
            enqueuedAtMs: enqueuedAtMs,
            lastSentAtMs: lastSentAtMs,
            attemptCount: attemptCount
        )
    }
}

private extension ReconnectStateRecord {
    var sharedEngineReconnectState: SharedEngineReconnectState {
        SharedEngineReconnectState(
            shouldReconnect: shouldReconnect,
            reconnectPending: reconnectPending,
            attemptCount: attemptCount,
            currentBackoffMs: currentBackoffMs,
            nextBackoffMs: nextBackoffMs,
            lastScheduledAtMs: lastScheduledAtMs,
            lastReconnectedAtMs: lastReconnectedAtMs,
            lastDisconnectReason: lastDisconnectReason
        )
    }
}

private extension ConnectionDiagnosticsRecord {
    var sharedEngineDiagnostics: SharedEngineDiagnostics {
        SharedEngineDiagnostics(
            connectAttempts: connectAttempts,
            successfulConnects: successfulConnects,
            disconnectCount: disconnectCount,
            authFailures: authFailures,
            protocolErrorCount: protocolErrorCount,
            transportErrorCount: transportErrorCount,
            lastErrorMessage: lastErrorMessage,
            lastResponseRequestID: lastResponseRequestId
        )
    }
}

private extension ClientConnectionState {
    var sharedEngineConnectionState: SharedEngineConnectionState {
        switch self {
        case .disconnected:
            return .disconnected
        case .connecting:
            return .connecting
        case .connected:
            return .connected
        case .error:
            return .error(nil)
        }
    }
}

private extension HostPlatform {
    var sharedEngineHostPlatform: SharedEngineHostPlatform {
        switch self {
        case .macos:
            return .macos
        case .linux:
            return .linux
        }
    }
}

private extension HostHealthStatus {
    var sharedEngineHostHealthStatus: SharedEngineHostHealthStatus {
        switch self {
        case .starting:
            return .starting
        case .ready:
            return .ready
        case .degraded:
            return .degraded
        case .failed:
            return .failed
        }
    }
}

private extension AppServerLifecycleState {
    var sharedEngineAppServerState: SharedEngineAppServerState {
        switch self {
        case .stopped:
            return .stopped
        case .starting:
            return .starting
        case .ready:
            return .ready
        case .degraded:
            return .degraded
        case .failed:
            return .failed
        }
    }
}

private extension CommandKind {
    var sharedEngineCommandKind: SharedEngineCommandKind {
        switch self {
        case .hello:
            return .hello
        case .getSnapshot:
            return .getSnapshot
        case .pairStart:
            return .pairStart
        case .pairConfirm:
            return .pairConfirm
        case .pairRevoke:
            return .pairRevoke
        case .appServerRequest:
            return .appServerRequest
        case .appServerResponse:
            return .appServerResponse
        case .appServerInterrupt:
            return .appServerInterrupt
        }
    }
}
