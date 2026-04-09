//
//  EngineShellAdapter.swift
//  CodexIsland
//
//  Swift-side compatibility boundary for the shared engine migration.
//

import Foundation

nonisolated enum SharedEngineConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case error(String?)
}

nonisolated enum SharedEngineHostPlatform: String, Equatable, Sendable {
    case macos
    case linux
}

nonisolated enum SharedEngineHostHealthStatus: String, Equatable, Sendable {
    case starting
    case ready
    case degraded
    case failed
}

nonisolated enum SharedEngineAppServerState: String, Equatable, Sendable {
    case stopped
    case starting
    case ready
    case degraded
    case failed
}

nonisolated enum SharedEngineCommandKind: String, Equatable, Sendable {
    case hello
    case getSnapshot
    case pairStart
    case pairConfirm
    case pairRevoke
    case appServerRequest
    case appServerResponse
    case appServerInterrupt
}

nonisolated struct SharedEngineQueuedCommand: Equatable, Sendable {
    let queueID: UInt64
    let kind: SharedEngineCommandKind
    let commandJSON: String
    let enqueuedAtMs: UInt64
    let lastSentAtMs: UInt64?
    let attemptCount: UInt32
}

nonisolated struct SharedEngineReconnectState: Equatable, Sendable {
    let shouldReconnect: Bool
    let reconnectPending: Bool
    let attemptCount: UInt32
    let currentBackoffMs: UInt64
    let nextBackoffMs: UInt64?
    let lastScheduledAtMs: UInt64?
    let lastReconnectedAtMs: UInt64?
    let lastDisconnectReason: String?
}

nonisolated struct SharedEngineDiagnostics: Equatable, Sendable {
    let connectAttempts: UInt32
    let successfulConnects: UInt32
    let disconnectCount: UInt32
    let authFailures: UInt32
    let protocolErrorCount: UInt32
    let transportErrorCount: UInt32
    let lastErrorMessage: String?
    let lastResponseRequestID: String?
}

nonisolated struct SharedEngineCapabilities: Equatable, Sendable {
    let pairing: Bool
    let appServerBridge: Bool
    let transcriptFallback: Bool
    let reconnectResume: Bool
}

nonisolated struct SharedEngineAppServerHealth: Equatable, Sendable {
    let state: SharedEngineAppServerState
    let launchCommand: [String]
    let cwd: String?
    let pid: UInt32?
    let lastExitCode: Int32?
    let lastError: String?
    let restartCount: UInt32
}

nonisolated struct SharedEngineHostHealth: Equatable, Sendable {
    let protocolVersion: String
    let daemonVersion: String
    let hostID: String
    let hostname: String
    let platform: SharedEngineHostPlatform
    let status: SharedEngineHostHealthStatus
    let startedAt: String
    let observedAt: String
    let appServer: SharedEngineAppServerHealth
    let capabilities: SharedEngineCapabilities
    let pairedDeviceCount: UInt32
}

nonisolated struct SharedEnginePairingSession: Equatable, Sendable {
    let pairingCode: String
    let sessionID: String
    let deviceName: String?
    let expiresAt: String
}

nonisolated struct SharedEnginePairedDevice: Equatable, Sendable {
    let deviceID: String
    let deviceName: String
    let platform: String
    let createdAt: String
    let lastSeenAt: String?
    let lastIP: String?
}

nonisolated struct SharedEngineSnapshot: Equatable, Sendable {
    let health: SharedEngineHostHealth
    let activePairing: SharedEnginePairingSession?
    let pairedDevices: [SharedEnginePairedDevice]
    let activeThreadID: String?
    let activeTurnID: String?
}

nonisolated struct SharedEngineRuntimeState: Equatable, Sendable {
    let connection: SharedEngineConnectionState
    let snapshot: SharedEngineSnapshot
    let authenticated: Bool
    let authToken: String?
    let lastErrorMessage: String?
    let lastAppServerEventJSON: String?
    let pendingCommands: [SharedEngineQueuedCommand]
    let inFlightCommand: SharedEngineQueuedCommand?
    let reconnect: SharedEngineReconnectState
    let diagnostics: SharedEngineDiagnostics
}

nonisolated enum EngineShellCommandIntent: Equatable, Sendable {
    case requestConnection
    case activateReconnectNow
    case getSnapshot
    case pairStart(deviceName: String, clientPlatform: String)
    case pairConfirm(pairingCode: String, deviceName: String, clientPlatform: String)
    case pairRevoke(deviceId: String)
    case appServerRequest(requestId: String, method: String, paramsJSON: String)
    case appServerResponse(requestId: String, resultJSON: String)
    case appServerInterrupt(threadId: String, turnId: String)
    case transportDisconnected(reason: String?)
    case replaceAuthToken(String?)
    case setShouldReconnect(Bool)
}

nonisolated protocol SharedEngineRuntimeDriving: Sendable {
    func currentState() -> SharedEngineRuntimeState
    func applyServerEvent(_ eventJSON: String) throws -> SharedEngineRuntimeState
    func popNextCommandJSON() -> String?
    @discardableResult
    func send(_ intent: EngineShellCommandIntent) throws -> SharedEngineRuntimeState?
}

final class EngineRuntimeCommandAdapter: SharedEngineRuntimeDriving, @unchecked Sendable {
    private let stateProvider: @Sendable () -> SharedEngineRuntimeState
    private let eventApplier: @Sendable (String) throws -> SharedEngineRuntimeState
    private let sender: @Sendable (EngineShellCommandIntent) throws -> SharedEngineRuntimeState?

    init(
        stateProvider: @escaping @Sendable () -> SharedEngineRuntimeState,
        eventApplier: @escaping @Sendable (String) throws -> SharedEngineRuntimeState,
        sender: @escaping @Sendable (EngineShellCommandIntent) throws -> SharedEngineRuntimeState?
    ) {
        self.stateProvider = stateProvider
        self.eventApplier = eventApplier
        self.sender = sender
    }

    func currentState() -> SharedEngineRuntimeState {
        stateProvider()
    }

    func applyServerEvent(_ eventJSON: String) throws -> SharedEngineRuntimeState {
        try eventApplier(eventJSON)
    }

    func popNextCommandJSON() -> String? {
        nil
    }

    @discardableResult
    func send(_ intent: EngineShellCommandIntent) throws -> SharedEngineRuntimeState? {
        try sender(intent)
    }
}

nonisolated struct EngineHostAdapterState: Equatable, Sendable {
    let hostID: String
    let hostName: String
    let protocolVersion: String
    let daemonVersion: String
    let authenticated: Bool
    let activeThreadID: String?
    let activeTurnID: String?
    let activePairingCode: String?
    let pairedDeviceCount: Int
    let connectionState: RemoteHostConnectionState
    let appServerState: String
    let reconnectSummary: String
    let queueSummary: String
    let diagnosticsSummary: String
    let lastErrorMessage: String?

    init(runtimeState: SharedEngineRuntimeState, preferredHostName: String? = nil) {
        let snapshot = runtimeState.snapshot
        let health = snapshot.health
        let trimmedPreferredName = preferredHostName?.trimmingCharacters(in: .whitespacesAndNewlines)

        hostID = health.hostID
        hostName = trimmedPreferredName?.isEmpty == false ? trimmedPreferredName! : health.hostname
        protocolVersion = health.protocolVersion
        daemonVersion = health.daemonVersion
        authenticated = runtimeState.authenticated
        activeThreadID = snapshot.activeThreadID
        activeTurnID = snapshot.activeTurnID
        activePairingCode = snapshot.activePairing?.pairingCode
        pairedDeviceCount = snapshot.pairedDevices.count
        connectionState = Self.makeConnectionState(from: runtimeState)
        appServerState = health.appServer.state.rawValue
        reconnectSummary = Self.makeReconnectSummary(from: runtimeState.reconnect)
        queueSummary = Self.makeQueueSummary(
            pending: runtimeState.pendingCommands,
            inFlight: runtimeState.inFlightCommand
        )
        diagnosticsSummary = Self.makeDiagnosticsSummary(from: runtimeState.diagnostics)
        lastErrorMessage = runtimeState.lastErrorMessage ??
            runtimeState.diagnostics.lastErrorMessage ??
            health.appServer.lastError
    }

    private static func makeConnectionState(from state: SharedEngineRuntimeState) -> RemoteHostConnectionState {
        switch state.connection {
        case .connected:
            return .connected
        case .connecting:
            return .connecting
        case .disconnected:
            if let message = state.lastErrorMessage, !message.isEmpty {
                return .failed(message)
            }
            return .disconnected
        case .error(let message):
            return .failed(message ?? "Shared engine connection failed")
        }
    }

    private static func makeReconnectSummary(from reconnect: SharedEngineReconnectState) -> String {
        if reconnect.reconnectPending {
            let next = reconnect.nextBackoffMs ?? reconnect.currentBackoffMs
            return "pending in \(next)ms"
        }
        if reconnect.shouldReconnect {
            return "armed"
        }
        return "idle"
    }

    private static func makeQueueSummary(
        pending: [SharedEngineQueuedCommand],
        inFlight: SharedEngineQueuedCommand?
    ) -> String {
        let inFlightSummary = inFlight.map { "\($0.kind.rawValue)#\($0.queueID)" } ?? "none"
        return "\(pending.count) pending / in-flight \(inFlightSummary)"
    }

    private static func makeDiagnosticsSummary(from diagnostics: SharedEngineDiagnostics) -> String {
        [
            "connect=\(diagnostics.connectAttempts)",
            "success=\(diagnostics.successfulConnects)",
            "disconnect=\(diagnostics.disconnectCount)",
            "transport=\(diagnostics.transportErrorCount)"
        ].joined(separator: " · ")
    }
}

nonisolated struct EngineThreadAdapterState: Equatable, Sendable {
    let hostID: String
    let hostName: String
    let threadID: String
    let logicalSessionID: String
    let activeTurnID: String?
    let phase: SessionPhase
    let connectionState: RemoteHostConnectionState
    let title: String
    let preview: String
    let cwd: String

    init?(
        runtimeState: SharedEngineRuntimeState,
        preferredHostName: String? = nil,
        cwd: String
    ) {
        guard let threadID = runtimeState.snapshot.activeThreadID else { return nil }
        let hostState = EngineHostAdapterState(runtimeState: runtimeState, preferredHostName: preferredHostName)

        hostID = hostState.hostID
        hostName = hostState.hostName
        self.threadID = threadID
        logicalSessionID = "engine-\(hostState.hostID)-\(threadID)"
        activeTurnID = runtimeState.snapshot.activeTurnID
        phase = Self.makePhase(from: runtimeState)
        connectionState = hostState.connectionState
        title = runtimeState.snapshot.activePairing == nil ? "Engine Session" : "Pairing Session"
        preview = runtimeState.snapshot.activeTurnID == nil ? "Shared engine thread" : "Shared engine active turn"
        self.cwd = cwd
    }

    func makeRemoteThreadState(now: Date = Date()) -> RemoteThreadState {
        RemoteThreadState(
            hostId: hostID,
            hostName: hostName,
            threadId: threadID,
            logicalSessionId: logicalSessionID,
            preview: preview,
            name: title,
            cwd: cwd,
            phase: phase,
            lastActivity: now,
            createdAt: now,
            updatedAt: now,
            lastMessage: nil,
            lastMessageRole: nil,
            lastToolName: nil,
            lastUserMessageDate: nil,
            history: [],
            activeTurnId: activeTurnID,
            isLoaded: false,
            canSteerTurn: activeTurnID != nil,
            pendingApproval: nil,
            pendingInteractions: [],
            connectionState: connectionState,
            turnContext: .empty,
            tokenUsage: nil
        )
    }

    private static func makePhase(from state: SharedEngineRuntimeState) -> SessionPhase {
        if state.snapshot.activeTurnID != nil {
            return .processing
        }
        if state.inFlightCommand != nil || !state.pendingCommands.isEmpty {
            return .processing
        }
        if state.authenticated, case .connected = state.connection {
            return .waitingForInput
        }
        return .idle
    }
}
