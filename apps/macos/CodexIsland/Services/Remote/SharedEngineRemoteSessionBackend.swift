//
//  SharedEngineRemoteSessionBackend.swift
//  CodexIsland
//
//  Shared-engine-backed remote/session backend scaffold for macOS migration.
//

import Combine
import Foundation

@MainActor
final class SharedEngineRemoteSessionBackend: ObservableObject, RemoteSessionControlling {
    @Published private(set) var hosts: [RemoteHostConfig]
    @Published private(set) var threads: [RemoteThreadState] = []
    @Published private(set) var hostStates: [String: RemoteHostConnectionState] = [:]
    @Published private(set) var hostActionErrors: [String: String] = [:]
    @Published private(set) var hostActionInProgress: Set<String> = []

    private let runtime: any SharedEngineRuntimeDriving
    private let hostID: String
    private let hostdProcess: BundledHostdProcess?
    private let webSocketTransport: LocalHostdWebSocketTransport?
    private let deviceName: String
    private let clientPlatform: String
    private let localStateDirectory: URL?

    var hostsPublisher: AnyPublisher<[RemoteHostConfig], Never> {
        $hosts.eraseToAnyPublisher()
    }

    var threadsPublisher: AnyPublisher<[RemoteThreadState], Never> {
        $threads.eraseToAnyPublisher()
    }

    var hostStatesPublisher: AnyPublisher<[String: RemoteHostConnectionState], Never> {
        $hostStates.eraseToAnyPublisher()
    }

    var hostActionErrorsPublisher: AnyPublisher<[String: String], Never> {
        $hostActionErrors.eraseToAnyPublisher()
    }

    var hostActionInProgressPublisher: AnyPublisher<Set<String>, Never> {
        $hostActionInProgress.eraseToAnyPublisher()
    }

    init(
        host: RemoteHostConfig,
        runtime: any SharedEngineRuntimeDriving
    ) {
        self.hosts = [host]
        self.hostID = host.id
        self.runtime = runtime
        self.hostdProcess = nil
        self.webSocketTransport = nil
        self.deviceName = "Codex Island macOS"
        self.clientPlatform = "macos"
        self.localStateDirectory = nil
        apply(runtimeState: runtime.currentState())
    }

    convenience init(localHost host: RemoteHostConfig) {
        let runtime = UniffiSharedEngineRuntimeDriver(
            clientName: "Codex Island macOS",
            clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
            authToken: nil
        )
        let bindAddress = "127.0.0.1:7331"
        let socketURL = URL(string: "ws://\(bindAddress)")!
        self.init(
            host: host,
            runtime: runtime,
            hostdProcess: BundledHostdProcess(),
            webSocketTransport: LocalHostdWebSocketTransport(url: socketURL),
            deviceName: "Codex Island macOS",
            clientPlatform: "macos",
            localStateDirectory: Self.defaultLocalStateDirectory()
        )
    }

    private init(
        host: RemoteHostConfig,
        runtime: any SharedEngineRuntimeDriving,
        hostdProcess: BundledHostdProcess?,
        webSocketTransport: LocalHostdWebSocketTransport?,
        deviceName: String,
        clientPlatform: String,
        localStateDirectory: URL?
    ) {
        self.hosts = [host]
        self.hostID = host.id
        self.runtime = runtime
        self.hostdProcess = hostdProcess
        self.webSocketTransport = webSocketTransport
        self.deviceName = deviceName
        self.clientPlatform = clientPlatform
        self.localStateDirectory = localStateDirectory
        apply(runtimeState: runtime.currentState())
    }

    func startMonitoring() {
        Task { @MainActor [weak self] in
            await self?.startEngineTransport()
        }
    }

    func createThread(hostId: String, onSuccess: @escaping @MainActor (RemoteThreadState) -> Void) {
        hostActionInProgress.insert(hostId)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.hostActionInProgress.remove(hostId) }
            do {
                let thread = try await self.startFreshThread(hostId: hostId)
                onSuccess(thread)
            } catch {
                self.hostActionErrors[hostId] = error.localizedDescription
            }
        }
    }

    func refreshHost(id: String) {
        guard id == hostID else { return }
        Task { @MainActor [weak self] in
            try? await self?.refreshHostNow(id: id)
        }
    }

    func refreshHostNow(id: String) async throws {
        guard id == hostID else { return }
        _ = try runtime.send(.getSnapshot)
        try await flushPendingCommands()
        apply(runtimeState: runtime.currentState())
    }

    func listModels(hostId: String, includeHidden: Bool) async throws -> [RemoteAppServerModel] {
        throw RemoteSessionError.transport("Shared engine backend has not wired model listing yet.")
    }

    func listCollaborationModes(hostId: String) async throws -> [RemoteAppServerCollaborationModeMask] {
        throw RemoteSessionError.transport("Shared engine backend has not wired collaboration mode listing yet.")
    }

    func addHost() {}

    func updateHost(_ host: RemoteHostConfig) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[index] = host
        apply(runtimeState: runtime.currentState())
    }

    func removeHost(id: String) {
        guard id == hostID else { return }
        hosts.removeAll { $0.id == id }
        threads = []
        hostStates[id] = .disconnected
    }

    func connectHost(id: String) {
        guard id == hostID else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try self.runtime.send(.requestConnection)
                _ = try self.runtime.send(.getSnapshot)
                try await self.flushPendingCommands()
                self.apply(runtimeState: self.runtime.currentState())
            } catch {
                self.hostActionErrors[id] = error.localizedDescription
            }
        }
    }

    func disconnectHost(id: String) {
        guard id == hostID else { return }
        do {
            _ = try runtime.send(.setShouldReconnect(false))
            _ = try runtime.send(.transportDisconnected(reason: "Disconnected by user"))
        } catch {
            hostActionErrors[id] = error.localizedDescription
        }
        webSocketTransport?.disconnect(reason: "Disconnected by user")
        hostdProcess?.stop()
        apply(runtimeState: runtime.currentState())
    }

    func startThread(hostId: String) async throws -> RemoteThreadState {
        try await startFreshThread(hostId: hostId)
    }

    func startFreshThread(hostId: String) async throws -> RemoteThreadState {
        let defaultCwd = hosts.first(where: { $0.id == hostId })?.defaultCwd ?? ""
        return try await startFreshThread(hostId: hostId, defaultCwd: defaultCwd)
    }

    func startFreshThread(hostId: String, defaultCwd: String) async throws -> RemoteThreadState {
        guard hostId == hostID else { throw RemoteSessionError.invalidConfiguration("Remote host no longer exists") }

        let payload = JSONEncoderPayload.object([
            "cwd": .string(defaultCwd)
        ]).jsonString

        _ = try runtime.send(.appServerRequest(
            requestId: "thread-start-\(UUID().uuidString)",
            method: "thread/start",
            paramsJSON: payload
        ))
        try await flushPendingCommands()
        apply(runtimeState: runtime.currentState())

        guard let thread = threads.first else {
            throw RemoteSessionError.missingThread
        }
        return thread
    }

    func openThread(hostId: String, threadId: String) async throws -> RemoteThreadState {
        guard hostId == hostID else { throw RemoteSessionError.invalidConfiguration("Remote host no longer exists") }

        let payload = JSONEncoderPayload.object([
            "threadId": .string(threadId)
        ]).jsonString

        _ = try runtime.send(.appServerRequest(
            requestId: "thread-resume-\(UUID().uuidString)",
            method: "thread/resume",
            paramsJSON: payload
        ))
        try await flushPendingCommands()
        apply(runtimeState: runtime.currentState())

        if let thread = findThread(hostId: hostId, threadId: threadId, transcriptPath: nil) {
            return thread
        }
        guard let thread = threads.first else {
            throw RemoteSessionError.missingThread
        }
        return thread
    }

    func sendMessage(thread: RemoteThreadState, text: String) async throws {
        let payload: String
        let method: String
        if let activeTurnId = thread.activeTurnId, thread.canSteerTurn {
            method = "turn/steer"
            payload = JSONEncoderPayload.object([
                "threadId": .string(thread.threadId),
                "expectedTurnId": .string(activeTurnId),
                "input": .array([.object(["type": .string("text"), "text": .string(text)])])
            ]).jsonString
        } else {
            method = "turn/start"
            payload = JSONEncoderPayload.object([
                "threadId": .string(thread.threadId),
                "input": .array([.object(["type": .string("text"), "text": .string(text)])])
            ]).jsonString
        }

        _ = try runtime.send(.appServerRequest(
            requestId: "\(method)-\(UUID().uuidString)",
            method: method,
            paramsJSON: payload
        ))
        try await flushPendingCommands()
        appendLocalInfoMessage(thread: thread, message: "Queued via shared engine: \(text)")
        apply(runtimeState: runtime.currentState())
    }

    func setTurnContext(
        thread: RemoteThreadState,
        turnContext desiredTurnContext: RemoteThreadTurnContext,
        synchronizeThread: Bool
    ) async throws -> RemoteThreadState {
        thread
    }

    func interrupt(thread: RemoteThreadState) async throws {
        guard let turnId = thread.activeTurnId else { return }
        _ = try runtime.send(.appServerInterrupt(threadId: thread.threadId, turnId: turnId))
        try await flushPendingCommands()
        apply(runtimeState: runtime.currentState())
    }

    func approve(thread: RemoteThreadState) async throws {
        try await respond(thread: thread, action: .allow)
    }

    func deny(thread: RemoteThreadState) async throws {
        try await respond(thread: thread, action: .deny)
    }

    func respond(thread: RemoteThreadState, action: PendingApprovalAction) async throws {
        let decision: String = action == .allow ? "accept" : "decline"
        _ = try runtime.send(.appServerResponse(
            requestId: "approval-\(thread.threadId)",
            resultJSON: JSONEncoderPayload.object(["decision": .string(decision)]).jsonString
        ))
        try await flushPendingCommands()
        apply(runtimeState: runtime.currentState())
    }

    func respond(
        thread: RemoteThreadState,
        interaction: PendingUserInputInteraction,
        answers: PendingInteractionAnswerPayload
    ) async throws {
        let serializedAnswers = answers.answers.mapValues { value in
            JSONEncoderPayload.object(["answers": .array(value.map(JSONEncoderPayload.string))])
        }
        _ = try runtime.send(.appServerResponse(
            requestId: interaction.remoteRequestID.stringValue,
            resultJSON: JSONEncoderPayload.object([
                "answers": .object(serializedAnswers)
            ]).jsonString
        ))
        try await flushPendingCommands()
        apply(runtimeState: runtime.currentState())
    }

    func availableThreads(hostId: String, excluding threadId: String?) -> [RemoteThreadState] {
        threads.filter { thread in
            thread.hostId == hostId && thread.threadId != threadId
        }
    }

    func findThread(hostId: String, threadId: String?, transcriptPath: String?) -> RemoteThreadState? {
        threads.first { thread in
            thread.hostId == hostId &&
                (threadId == nil || thread.threadId == threadId)
        }
    }

    func appendLocalInfoMessage(thread: RemoteThreadState, message: String) {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else { return }
        threads[index].history.append(
            ChatHistoryItem(
                id: "shared-engine-info-\(UUID().uuidString)",
                type: .assistant(message),
                timestamp: Date()
            )
        )
        threads[index].updatedAt = Date()
    }

    func applyServerEventJSON(_ eventJSON: String) throws {
        let state = try runtime.applyServerEvent(eventJSON)
        handleProtocolEvent(eventJSON)
        apply(runtimeState: state)
    }

    private func startEngineTransport() async {
        do {
            if let hostdProcess, let localStateDirectory {
                try hostdProcess.start(bindAddress: "127.0.0.1:7331", stateDirectory: localStateDirectory)
            }

            webSocketTransport?.connect(
                onMessage: { [weak self] text in
                    Task { @MainActor in
                        try? self?.applyServerEventJSON(text)
                        try? await self?.flushPendingCommands()
                    }
                },
                onDisconnect: { [weak self] reason in
                    guard let self else { return }
                    _ = try? self.runtime.send(.transportDisconnected(reason: reason))
                    self.apply(runtimeState: self.runtime.currentState())
                }
            )

            _ = try runtime.send(.requestConnection)
            _ = try runtime.send(.getSnapshot)
            try await flushPendingCommands()
            apply(runtimeState: runtime.currentState())
        } catch {
            hostActionErrors[hostID] = error.localizedDescription
            hostStates[hostID] = .failed(error.localizedDescription)
        }
    }

    private func flushPendingCommands() async throws {
        while let commandJSON = runtime.popNextCommandJSON() {
            try await webSocketTransport?.send(commandJSON)
        }
    }

    private func handleProtocolEvent(_ eventJSON: String) {
        guard let data = eventJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return
        }

        switch type {
        case "pairing_started":
            guard let pairing = object["pairing"] as? [String: Any],
                  let code = pairing["pairing_code"] as? String else {
                return
            }
            _ = try? runtime.send(.pairConfirm(
                pairingCode: code,
                deviceName: deviceName,
                clientPlatform: clientPlatform
            ))
        case "pairing_completed":
            _ = try? runtime.send(.requestConnection)
            _ = try? runtime.send(.getSnapshot)
        default:
            break
        }
    }

    private func apply(runtimeState: SharedEngineRuntimeState) {
        guard let host = hosts.first(where: { $0.id == hostID }) else {
            threads = []
            hostStates[hostID] = .disconnected
            return
        }

        let hostProjection = EngineHostAdapterState(runtimeState: runtimeState, preferredHostName: host.displayName)
        hostStates[hostID] = hostProjection.connectionState

        if let threadProjection = EngineThreadAdapterState(
            runtimeState: runtimeState,
            preferredHostName: host.displayName,
            cwd: runtimeState.snapshot.health.appServer.cwd ?? host.defaultCwd
        ) {
            let previousHistory = findThread(hostId: hostID, threadId: threadProjection.threadID, transcriptPath: nil)?.history ?? []
            var projected = threadProjection.makeRemoteThreadState()
            projected.history = previousHistory
            threads = [projected]
        } else {
            threads = []
        }

        if let lastError = hostProjection.lastErrorMessage, !lastError.isEmpty {
            hostActionErrors[hostID] = lastError
        } else {
            hostActionErrors.removeValue(forKey: hostID)
        }
    }

    private static func defaultLocalStateDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("CodexIsland/hostd", isDirectory: true)
    }
}

private enum JSONEncoderPayload {
    case string(String)
    case array([JSONEncoderPayload])
    case object([String: JSONEncoderPayload])

    var jsonString: String {
        switch self {
        case .string(let value):
            return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
        case .array(let values):
            return "[" + values.map(\.jsonString).joined(separator: ",") + "]"
        case .object(let values):
            let body = values.map { key, value in
                "\"\(key)\":\(value.jsonString)"
            }
            .sorted()
            .joined(separator: ",")
            return "{\(body)}"
        }
    }
}

private extension RemoteRPCID {
    var stringValue: String {
        switch self {
        case .int(let value):
            return String(value)
        case .string(let value):
            return value
        }
    }
}
