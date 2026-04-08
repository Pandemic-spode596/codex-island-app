//
//  RemoteSessionMonitor.swift
//  CodexIsland
//
//  SSH-managed app-server client for remote thread listing and interaction.
//

import Combine
import Foundation

enum RemoteConnectionEvent: Sendable {
    case connectionState(hostId: String, state: RemoteHostConnectionState)
    case threadList(hostId: String, threads: [RemoteAppServerThread])
    case threadUpsert(hostId: String, thread: RemoteAppServerThread)
    case threadStatusChanged(hostId: String, threadId: String, status: RemoteAppServerThreadStatus)
    case turnStarted(hostId: String, threadId: String, turn: RemoteAppServerTurn)
    case turnCompleted(hostId: String, threadId: String, turn: RemoteAppServerTurn)
    case turnPlanUpdated(
        hostId: String,
        threadId: String,
        turnId: String,
        explanation: String?,
        plan: [RemoteAppServerPlanStep]
    )
    case tokenUsageUpdated(hostId: String, threadId: String, turnId: String, tokenUsage: SessionTokenUsageInfo)
    case itemStarted(hostId: String, threadId: String, turnId: String, item: RemoteAppServerThreadItem)
    case itemCompleted(hostId: String, threadId: String, turnId: String, item: RemoteAppServerThreadItem)
    case agentMessageDelta(hostId: String, threadId: String, turnId: String, itemId: String, delta: String)
    case approval(hostId: String, threadId: String, approval: RemotePendingApproval)
    case userInputRequest(hostId: String, threadId: String, interaction: PendingUserInputInteraction)
    case serverRequestResolved(hostId: String, threadId: String, requestId: RemoteRPCID)
    case threadError(hostId: String, threadId: String, turnId: String?, message: String, willRetry: Bool)
}

nonisolated struct RemoteTranscriptFallbackSnapshot: Sendable {
    let history: [ChatHistoryItem]
    let pendingInteractions: [PendingInteraction]
    let transcriptPhase: SessionPhase?
    let runtimeInfo: SessionRuntimeInfo
}

enum RemoteSessionError: LocalizedError {
    case notConnected
    case missingThread
    case invalidConfiguration(String)
    case transport(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Remote host is not connected"
        case .missingThread:
            return "Remote thread not found"
        case .invalidConfiguration(let message), .transport(let message), .timeout(let message):
            return message
        }
    }
}

nonisolated protocol RemoteAppServerConnectionProtocol: Sendable {
    func updateHost(_ host: RemoteHostConfig) async
    func start() async
    func stop() async
    func normalizeCwd(_ cwd: String) async throws -> String?
    func resolveDisplayCwdFilter(_ cwd: String) async throws -> String?
    func startThread(defaultCwd: String) async throws -> RemoteAppServerThreadStartResponse
    func resumeThread(
        threadId: String,
        turnContext: RemoteThreadTurnContext?
    ) async throws -> RemoteAppServerThreadResumeResponse
    func sendMessage(
        threadId: String,
        text: String,
        activeTurnId: String?,
        turnContext: RemoteThreadTurnContext
    ) async throws
    func interrupt(threadId: String, turnId: String) async throws
    func respond(to approval: RemotePendingApproval, allow: Bool) async throws
    func respond(to approval: RemotePendingApproval, action: PendingApprovalAction) async throws
    func respond(to interaction: PendingUserInputInteraction, answers: PendingInteractionAnswerPayload) async throws
    func refreshThreads() async throws
    func listModels(includeHidden: Bool) async throws -> [RemoteAppServerModel]
    func listCollaborationModes() async throws -> [RemoteAppServerCollaborationModeMask]
    func loadTranscriptFallbackContent(
        transcriptPath: String,
        maxBytes: Int
    ) async throws -> String?
}

extension RemoteAppServerConnectionProtocol {
    func resolveDisplayCwdFilter(_ cwd: String) async throws -> String? {
        try await normalizeCwd(cwd)
    }
}

nonisolated struct RemoteAppServerConnectionDependencies: Sendable {
    let transportFactory: @Sendable (RemoteHostConfig) -> any RemoteAppServerTransport
    let processExecutor: any ProcessExecuting
    let diagnosticsLogger: any RemoteDiagnosticsLogging
    let requestTimeout: Duration
    let initialRefreshDelay: Duration
    let refreshInterval: Duration
    let sleep: @Sendable (Duration) async throws -> Void

    static let live = RemoteAppServerConnectionDependencies(
        transportFactory: { SSHStdioTransport(host: $0) },
        processExecutor: ProcessExecutor.shared,
        diagnosticsLogger: RemoteDiagnosticsLogger.shared,
        requestTimeout: .seconds(10),
        initialRefreshDelay: .seconds(5),
        refreshInterval: .seconds(15),
        sleep: { duration in
            try await Task.sleep(for: duration)
        }
    )

    static let local = RemoteAppServerConnectionDependencies(
        transportFactory: { _ in LocalCodexAppServerTransport() },
        processExecutor: ProcessExecutor.shared,
        diagnosticsLogger: RemoteDiagnosticsLogger.shared,
        requestTimeout: .seconds(10),
        initialRefreshDelay: .seconds(5),
        refreshInterval: .seconds(15),
        sleep: { duration in
            try await Task.sleep(for: duration)
        }
    )
}

actor RemoteRequestSerialGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
            return
        }

        let continuation = waiters.removeFirst()
        continuation.resume()
    }

    func withPermit<T>(_ operation: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }
}

private func withTimeout<T: Sendable>(
    _ timeout: Duration,
    errorMessage: String,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
        try await Task.sleep(for: duration)
    },
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await sleep(timeout)
            throw RemoteSessionError.timeout(errorMessage)
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

@MainActor
final class RemoteSessionMonitor: ObservableObject {
    private struct OptimisticRemoteUserMessage: Sendable {
        let localId: String
        let hostId: String
        let threadId: String
        let text: String
        let createdAt: Date
    }

    static let shared = RemoteSessionMonitor()

    @Published private(set) var hosts: [RemoteHostConfig]
    @Published private(set) var threads: [RemoteThreadState] = []
    @Published private(set) var hostStates: [String: RemoteHostConnectionState] = [:]
    @Published private(set) var hostActionErrors: [String: String] = [:]
    @Published private(set) var hostActionInProgress: Set<String> = []

    private let transcriptFallbackProvisionalBusyWindow: TimeInterval = 15
    private let transcriptFallbackSSHTimeout: Duration
    private let transcriptFallbackParseTimeout: Duration
    private let transcriptFallbackApplyTimeout: Duration
    private let transcriptFallbackMaxBytes: Int

    private let saveHosts: ([RemoteHostConfig]) -> Void
    private let connectionFactory: (
        RemoteHostConfig,
        @escaping @Sendable (RemoteConnectionEvent) async -> Void
    ) -> any RemoteAppServerConnectionProtocol
    private let diagnosticsLogger: any RemoteDiagnosticsLogging

    private var connections: [String: any RemoteAppServerConnectionProtocol] = [:]
    private var hostActionTasks: [String: Task<Void, Never>] = [:]
    private var hostThreadFilters: [String: String] = [:]
    private var hostThreadFilterTasks: [String: Task<Void, Never>] = [:]
    private var optimisticUserMessages: [OptimisticRemoteUserMessage] = []
    private var rawThreadsByHost: [String: [String: RemoteAppServerThread]] = [:]
    private var preferredThreadBindings: [String: String] = [:]
    private var transcriptSyncTasks: [String: Task<Void, Never>] = [:]

    init(
        initialHosts: [RemoteHostConfig]? = nil,
        loadHosts: (() -> [RemoteHostConfig])? = nil,
        saveHosts: (([RemoteHostConfig]) -> Void)? = nil,
        diagnosticsLogger: any RemoteDiagnosticsLogging = RemoteDiagnosticsLogger.shared,
        transcriptFallbackSSHTimeout: Duration = .seconds(8),
        transcriptFallbackParseTimeout: Duration = .seconds(2),
        transcriptFallbackApplyTimeout: Duration = .seconds(1),
        transcriptFallbackMaxBytes: Int = 256 * 1024,
        connectionFactory: @escaping (
            RemoteHostConfig,
            @escaping @Sendable (RemoteConnectionEvent) async -> Void
        ) -> any RemoteAppServerConnectionProtocol = { host, emit in
            RemoteAppServerConnection(host: host, emit: emit)
        }
    ) {
        self.hosts = initialHosts ?? loadHosts?() ?? AppSettings.remoteHosts
        self.saveHosts = saveHosts ?? { AppSettings.remoteHosts = $0 }
        self.diagnosticsLogger = diagnosticsLogger
        self.transcriptFallbackSSHTimeout = transcriptFallbackSSHTimeout
        self.transcriptFallbackParseTimeout = transcriptFallbackParseTimeout
        self.transcriptFallbackApplyTimeout = transcriptFallbackApplyTimeout
        self.transcriptFallbackMaxBytes = transcriptFallbackMaxBytes
        self.connectionFactory = connectionFactory
    }

    private func markStateChanged() {
        objectWillChange.send()
    }

    private func normalizeSSHIdentity(_ sshTarget: String) -> String {
        sshTarget.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func hasEquivalentRemoteEndpoint(_ lhs: RemoteHostConfig, _ rhs: RemoteHostConfig) -> Bool {
        normalizeSSHIdentity(lhs.sshTarget) == normalizeSSHIdentity(rhs.sshTarget)
    }

    private func normalizeCwdIdentity(_ cwd: String) -> String {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.hasPrefix("/") else { return trimmed }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private func logicalSessionId(sshTarget: String, cwd: String) -> String {
        "remote|\(normalizeSSHIdentity(sshTarget))|\(normalizeCwdIdentity(cwd))"
    }

    private func logicalSessionId(for host: RemoteHostConfig, cwd: String) -> String {
        logicalSessionId(sshTarget: host.sshTarget, cwd: cwd)
    }

    private func threadIndex(logicalSessionId: String) -> Int? {
        threads.firstIndex(where: { $0.logicalSessionId == logicalSessionId })
    }

    private func threadState(hostId: String, threadId: String) -> RemoteThreadState? {
        guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return nil }
        return threads[index]
    }

    private func rawThreads(hostId: String) -> [RemoteAppServerThread] {
        Array(rawThreadsByHost[hostId, default: [:]].values)
    }

    private func replaceRawThreads(
        hostId: String,
        with remoteThreads: [RemoteAppServerThread],
        retaining retainedThreads: [RemoteAppServerThread] = []
    ) {
        var mergedThreads = Dictionary(uniqueKeysWithValues: remoteThreads.map { ($0.id, $0) })
        for thread in retainedThreads where mergedThreads[thread.id] == nil {
            mergedThreads[thread.id] = thread
        }
        rawThreadsByHost[hostId] = mergedThreads
    }

    private func upsertRawThread(hostId: String, thread: RemoteAppServerThread) {
        rawThreadsByHost[hostId, default: [:]][thread.id] = thread
    }

    private func removeRawThreads(hostId: String) {
        rawThreadsByHost.removeValue(forKey: hostId)
        optimisticUserMessages.removeAll { $0.hostId == hostId }
    }

    private func resetHostRuntimeState(
        hostId: String,
        clearConnectionState: Bool,
        additionalSSHIdentities: [String] = []
    ) {
        hostActionTasks[hostId]?.cancel()
        hostActionTasks.removeValue(forKey: hostId)
        hostActionInProgress.remove(hostId)
        hostActionErrors.removeValue(forKey: hostId)
        hostThreadFilterTasks[hostId]?.cancel()
        hostThreadFilterTasks.removeValue(forKey: hostId)
        hostThreadFilters.removeValue(forKey: hostId)
        clearPreferredThreadBindings(for: hostId, additionalSSHIdentities: additionalSSHIdentities)
        threads.removeAll { $0.hostId == hostId }
        removeRawThreads(hostId: hostId)
        if clearConnectionState {
            hostStates[hostId] = .disconnected
        }
    }

    private func clearPreferredThreadBinding(logicalSessionId: String) {
        preferredThreadBindings.removeValue(forKey: logicalSessionId)
    }

    private func setPreferredThreadBinding(logicalSessionId: String, threadId: String, reason: String) {
        preferredThreadBindings[logicalSessionId] = threadId
        if let hostId = threads.first(where: { $0.logicalSessionId == logicalSessionId })?.hostId {
            Task {
                await self.logMonitorEvent(
                    level: .debug,
                    hostId: hostId,
                    threadId: threadId,
                    message: "Updated preferred remote thread binding",
                    payload: "logicalSessionId=\(logicalSessionId) threadId=\(threadId) reason=\(reason)"
                )
            }
        }
    }

    private func clearPreferredThreadBindings(
        for hostId: String,
        additionalSSHIdentities: [String] = []
    ) {
        let sshTargets = Set(
            ([hosts.first(where: { $0.id == hostId })?.sshTarget] + additionalSSHIdentities)
                .compactMap { $0 }
                .map(normalizeSSHIdentity)
        )
        let rawLogicalIds = rawThreads(hostId: hostId).flatMap { rawThread in
            sshTargets.map { sshTarget in
                logicalSessionId(sshTarget: sshTarget, cwd: rawThread.cwd)
            }
        }
        let hostLogicalIds = Set(rawLogicalIds + threads.filter { $0.hostId == hostId }.map(\.logicalSessionId))
        for logicalSessionId in hostLogicalIds {
            preferredThreadBindings.removeValue(forKey: logicalSessionId)
        }
    }

    private func latestThread(from candidates: [RemoteAppServerThread]) -> RemoteAppServerThread? {
        candidates.max(by: { lhs, rhs in
            let lhsPriority = visibleThreadPriority(for: lhs)
            let rhsPriority = visibleThreadPriority(for: rhs)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt < rhs.updatedAt
            }
            return lhs.createdAt < rhs.createdAt
        })
    }

    private func visibleThreadPriority(for thread: RemoteAppServerThread) -> Int {
        let currentPhase = inferredVisiblePhase(for: thread)

        switch currentPhase {
        case .waitingForApproval, .processing, .compacting:
            return 2
        case .waitingForInput:
            return 1
        case .idle, .ended:
            return 0
        }
    }

    private func inferredVisiblePhase(for thread: RemoteAppServerThread) -> SessionPhase {
        phase(
            from: thread.status,
            pendingApproval: nil,
            activeTurnId: RemoteThreadHistoryMapper.activeTurn(from: thread.turns)?.id
        )
    }

    private func visibleThreadCandidateSummary(_ thread: RemoteAppServerThread) -> String {
        let activeTurnId = RemoteThreadHistoryMapper.activeTurn(from: thread.turns)?.id ?? "-"
        let inferredPhase = inferredVisiblePhase(for: thread).description
        let priority = visibleThreadPriority(for: thread)
        return "\(thread.id){status:\(thread.status),phase:\(inferredPhase),priority:\(priority),activeTurn:\(activeTurnId),updatedAt:\(thread.updatedAt)}"
    }

    private func rawThreadSummary(_ thread: RemoteAppServerThread) -> String {
        let preview = thread.preview.replacingOccurrences(of: "\n", with: " ")
        let compactPreview = String(preview.prefix(40))
        let path = thread.path?.replacingOccurrences(of: "\n", with: " ") ?? "-"
        return "\(thread.id){cwd:\(thread.cwd),path:\(path),status:\(thread.status),updatedAt:\(thread.updatedAt),preview:\(compactPreview)}"
    }

    private func retainedPreferredThreads(
        hostId: String,
        host: RemoteHostConfig?,
        remoteThreads: [RemoteAppServerThread]
    ) -> [RemoteAppServerThread] {
        // Refreshes can temporarily omit the thread currently shown in the UI
        // while a host is reconnecting or applying filters. We retain preferred
        // raw threads so the visible logical session does not disappear and then
        // reappear a moment later.
        let remoteThreadIds = Set(remoteThreads.map(\.id))
        return rawThreads(hostId: hostId).filter { thread in
            guard !remoteThreadIds.contains(thread.id) else { return false }
            guard shouldDisplayThread(thread, for: host) else { return false }
            let logicalSessionId = self.logicalSessionId(
                sshTarget: host?.sshTarget ?? "",
                cwd: thread.cwd
            )
            return preferredThreadBindings[logicalSessionId] == thread.id
        }
    }

    private func provisionalThreadFilter(for host: RemoteHostConfig) -> String? {
        let trimmed = host.defaultCwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else { return nil }
        return normalizeCwdIdentity(trimmed)
    }

    private func effectiveThreadFilter(for host: RemoteHostConfig?) -> String? {
        guard let host else { return nil }
        return hostThreadFilters[host.id] ?? provisionalThreadFilter(for: host)
    }

    private func shouldDisplayThread(_ thread: RemoteAppServerThread, for host: RemoteHostConfig?) -> Bool {
        guard let filter = effectiveThreadFilter(for: host) else { return true }
        return normalizeCwdIdentity(thread.cwd) == filter
    }

    private func applyThreadFilter(for host: RemoteHostConfig) {
        guard let filter = effectiveThreadFilter(for: host) else { return }
        threads.removeAll { $0.hostId == host.id && normalizeCwdIdentity($0.cwd) != filter }
    }

    private func resolveThreadFilter(for host: RemoteHostConfig) {
        hostThreadFilterTasks[host.id]?.cancel()

        // defaultCwd is applied in two stages: first with a cheap local
        // normalized path, then upgraded with a server-resolved display filter
        // once the remote connection can canonicalize symlinks/home expansion.
        if let provisional = provisionalThreadFilter(for: host) {
            hostThreadFilters[host.id] = provisional
            applyThreadFilter(for: host)
        } else if host.defaultCwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hostThreadFilters.removeValue(forKey: host.id)
        }

        guard let connection = connections[host.id],
              !host.defaultCwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let hostId = host.id
        let expectedSSH = host.sshTarget
        let expectedDefaultCwd = host.defaultCwd
        hostThreadFilterTasks[hostId] = Task { [weak self] in
            guard let self else { return }
            let resolvedFilter: String?
            do {
                resolvedFilter = try await connection.resolveDisplayCwdFilter(expectedDefaultCwd)
            } catch {
                let presentableError = await MainActor.run {
                    self.presentableRemoteError(error, hostId: hostId)
                }
                await self.logMonitorEvent(
                    level: .warning,
                    hostId: hostId,
                    method: "thread/list",
                    message: "Failed to resolve remote thread filter",
                    payload: presentableError.localizedDescription
                )
                return
            }
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let currentHost = self.hosts.first(where: { $0.id == hostId }),
                      currentHost.sshTarget == expectedSSH,
                      currentHost.defaultCwd == expectedDefaultCwd else {
                    return
                }

                let normalizedFilter = resolvedFilter.map(self.normalizeCwdIdentity)
                if let normalizedFilter {
                    self.hostThreadFilters[hostId] = normalizedFilter
                    self.applyThreadFilter(for: currentHost)
                } else if expectedDefaultCwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.hostThreadFilters.removeValue(forKey: hostId)
                }
                self.hostThreadFilterTasks.removeValue(forKey: hostId)
            }
        }
    }

    func startMonitoring() {
        syncConnections()
    }

    func createThread(
        hostId: String,
        onSuccess: @escaping @MainActor (RemoteThreadState) -> Void
    ) {
        markStateChanged()
        hostActionErrors.removeValue(forKey: hostId)
        hostActionInProgress.insert(hostId)
        hostActionTasks[hostId]?.cancel()

        hostActionTasks[hostId] = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let knownThreadIds = await MainActor.run {
                Set(self.threads.filter { $0.hostId == hostId }.map(\.threadId))
            }
            defer {
                Task { @MainActor in
                    self.markStateChanged()
                    self.hostActionInProgress.remove(hostId)
                    self.hostActionTasks.removeValue(forKey: hostId)
                }
            }

            do {
                let thread = try await self.startThread(hostId: hostId)
                let openedThread: RemoteThreadState
                let shouldHydrateExistingThread =
                    knownThreadIds.contains(thread.threadId) &&
                    (!thread.isLoaded || thread.history.isEmpty)

                if shouldHydrateExistingThread {
                    openedThread = try await self.openThread(hostId: hostId, threadId: thread.threadId)
                } else {
                    openedThread = thread
                }
                await onSuccess(openedThread)
            } catch {
                await MainActor.run {
                    self.markStateChanged()
                    if let state = self.hostStates[hostId],
                       case .failed(let message) = state,
                       !message.isEmpty {
                        self.hostActionErrors[hostId] = message
                    } else if error is CancellationError {
                        self.hostActionErrors[hostId] = "Remote request was canceled. Reconnect and retry."
                    } else {
                        self.hostActionErrors[hostId] = error.localizedDescription
                    }
                }
                return
            }
        }
    }

    func refreshHost(id: String) {
        guard let connection = connections[id] else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await connection.refreshThreads()
                self.hostActionErrors.removeValue(forKey: id)
            } catch {
                let presentableError = self.presentableRemoteError(error, hostId: id)
                self.hostActionErrors[id] = presentableError.localizedDescription
                await self.logMonitorEvent(
                    level: .warning,
                    hostId: id,
                    method: "thread/list",
                    message: "Manual refresh failed",
                    payload: presentableError.localizedDescription
                )
            }
        }
    }

    func refreshHostNow(id: String) async throws {
        guard let connection = connections[id] else { throw connectionAvailabilityError(hostId: id) }
        do {
            try await connection.refreshThreads()
            hostActionErrors.removeValue(forKey: id)
        } catch {
            let presentableError = presentableRemoteError(error, hostId: id)
            hostActionErrors[id] = presentableError.localizedDescription
            await logMonitorEvent(
                level: .warning,
                hostId: id,
                method: "thread/list",
                message: "Foreground refresh failed",
                payload: presentableError.localizedDescription
            )
            throw presentableError
        }
    }

    func listModels(hostId: String, includeHidden: Bool = false) async throws -> [RemoteAppServerModel] {
        guard let connection = connections[hostId] else {
            throw connectionAvailabilityError(hostId: hostId)
        }
        do {
            return try await connection.listModels(includeHidden: includeHidden)
        } catch {
            throw presentableRemoteError(error, hostId: hostId)
        }
    }

    func listCollaborationModes(hostId: String) async throws -> [RemoteAppServerCollaborationModeMask] {
        guard let connection = connections[hostId] else {
            throw connectionAvailabilityError(hostId: hostId)
        }
        do {
            return try await connection.listCollaborationModes()
        } catch {
            throw presentableRemoteError(error, hostId: hostId)
        }
    }

    func addHost() {
        hosts.append(RemoteHostConfig())
        persistHosts()
    }

    func updateHost(_ host: RemoteHostConfig) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        let previous = hosts[index]
        let endpointChanged = !hasEquivalentRemoteEndpoint(previous, host)

        if endpointChanged, let connection = connections.removeValue(forKey: host.id) {
            Task { await connection.stop() }
        }

        if endpointChanged {
            resetHostRuntimeState(
                hostId: host.id,
                clearConnectionState: true,
                additionalSSHIdentities: [previous.sshTarget, host.sshTarget]
            )
        }

        hosts[index] = host
        saveHosts(hosts)

        let connectionState = hostStates[host.id] ?? .disconnected
        let shouldSync = endpointChanged || previous.isEnabled != host.isEnabled || !connectionState.isConnected
        resolveThreadFilter(for: host)
        if shouldSync {
            syncConnections()
        }
    }

    func removeHost(id: String) {
        markStateChanged()
        clearPreferredThreadBindings(for: id)
        hosts.removeAll { $0.id == id }
        hostStates.removeValue(forKey: id)
        threads.removeAll { $0.hostId == id }
        removeRawThreads(hostId: id)
        hostThreadFilters.removeValue(forKey: id)
        hostThreadFilterTasks[id]?.cancel()
        hostThreadFilterTasks.removeValue(forKey: id)
        if let connection = connections.removeValue(forKey: id) {
            Task { await connection.stop() }
        }
        persistHosts()
    }

    func connectHost(id: String) {
        guard let host = hosts.first(where: { $0.id == id }) else { return }
        markStateChanged()
        if case .connecting = hostStates[id] {
            return
        }
        hostActionErrors.removeValue(forKey: id)
        if !host.isEnabled {
            var updated = host
            updated.isEnabled = true
            updateHost(updated)
            return
        }
        if let connection = connections.removeValue(forKey: id) {
            Task { await connection.stop() }
        }
        hostStates[id] = .connecting
        syncConnections()
    }

    func disconnectHost(id: String) {
        markStateChanged()
        hostStates[id] = .disconnected
        hostActionErrors.removeValue(forKey: id)
        hostActionInProgress.remove(id)
        hostActionTasks[id]?.cancel()
        hostActionTasks.removeValue(forKey: id)
        hostThreadFilterTasks[id]?.cancel()
        hostThreadFilterTasks.removeValue(forKey: id)
        clearPreferredThreadBindings(for: id)
        threads.removeAll { $0.hostId == id }
        removeRawThreads(hostId: id)
        if let connection = connections.removeValue(forKey: id) {
            Task { await connection.stop() }
        }
    }

    func startThread(hostId: String) async throws -> RemoteThreadState {
        try await startThread(
            hostId: hostId,
            reusingExistingLogicalSession: true,
            pinPreferredBinding: false,
            defaultCwdOverride: nil
        )
    }

    func startFreshThread(hostId: String) async throws -> RemoteThreadState {
        try await startThread(
            hostId: hostId,
            reusingExistingLogicalSession: false,
            pinPreferredBinding: true,
            defaultCwdOverride: nil
        )
    }

    func startFreshThread(hostId: String, defaultCwd: String) async throws -> RemoteThreadState {
        try await startThread(
            hostId: hostId,
            reusingExistingLogicalSession: false,
            pinPreferredBinding: true,
            defaultCwdOverride: defaultCwd
        )
    }

    private func startThread(
        hostId: String,
        reusingExistingLogicalSession: Bool,
        pinPreferredBinding: Bool,
        defaultCwdOverride: String?
    ) async throws -> RemoteThreadState {
        guard let host = hosts.first(where: { $0.id == hostId }) else {
            throw RemoteSessionError.invalidConfiguration("Remote host no longer exists")
        }
        guard let connection = connections[hostId] else {
            throw connectionAvailabilityError(hostId: hostId)
        }
        let requestedDefaultCwd = defaultCwdOverride ?? host.defaultCwd
        let normalizedDefaultCwd = try await connection.normalizeCwd(requestedDefaultCwd)
        if reusingExistingLogicalSession,
           let normalizedDefaultCwd,
           let existingThread = threads.first(where: {
               $0.hostId == hostId &&
                   $0.logicalSessionId == logicalSessionId(for: host, cwd: normalizedDefaultCwd)
           }) {
            return existingThread
        }
        let existingThreadIds = Set(rawThreads(hostId: hostId).map(\.id))

        do {
            let response = try await connection.startThread(defaultCwd: requestedDefaultCwd)
            let thread = response.thread
            markStateChanged()
            hostActionErrors.removeValue(forKey: hostId)
            let logicalSessionId = logicalSessionId(
                sshTarget: host.sshTarget,
                cwd: thread.cwd
            )
            if pinPreferredBinding {
                setPreferredThreadBinding(
                    logicalSessionId: logicalSessionId,
                    threadId: thread.id,
                    reason: "thread-start"
                )
            }
            upsertRawThread(hostId: hostId, thread: thread)
            refreshVisibleLogicalSession(hostId: hostId, logicalSessionId: logicalSessionId)
            updateTurnContextSnapshot(
                hostId: hostId,
                threadId: thread.id,
                snapshot: turnContext(from: response)
            )
            await logMonitorEvent(
                level: .info,
                hostId: hostId,
                method: "thread/start",
                threadId: thread.id,
                message: "Started remote thread"
            )
            scheduleFollowUpRefresh(
                hostId: hostId,
                connection: connection,
                reason: "thread/start",
                threadId: thread.id,
                surfaceErrorToUser: true
            )
            guard let state = threadState(hostId: hostId, threadId: thread.id) else {
                throw RemoteSessionError.missingThread
            }
            return state
        } catch {
            let presentableError = presentableRemoteError(error, hostId: hostId)
            markStateChanged()
            if case .timeout = (error as? RemoteSessionError) {
                do {
                    try await connection.refreshThreads()
                } catch {
                    let refreshError = presentableRemoteError(error, hostId: hostId)
                    await logMonitorEvent(
                        level: .warning,
                        hostId: hostId,
                        method: "thread/list",
                        message: "Failed timeout recovery refresh after thread start",
                        payload: refreshError.localizedDescription
                    )
                }
                if let recovered = recoverNewThread(
                    hostId: hostId,
                    excluding: existingThreadIds,
                    pinPreferredBinding: pinPreferredBinding
                ) {
                    hostActionErrors.removeValue(forKey: hostId)
                    await logMonitorEvent(
                        level: .warning,
                        hostId: hostId,
                        method: "thread/start",
                        threadId: recovered.threadId,
                        message: "Recovered remote thread after timeout fallback"
                    )
                    return recovered
                }
            }
            hostActionErrors[hostId] = presentableError.localizedDescription
            await logMonitorEvent(
                level: .error,
                hostId: hostId,
                method: "thread/start",
                message: "Failed to start remote thread",
                payload: presentableError.localizedDescription
            )
            throw presentableError
        }
    }

    func openThread(hostId: String, threadId: String) async throws -> RemoteThreadState {
        guard let connection = connections[hostId] else {
            throw connectionAvailabilityError(hostId: hostId)
        }
        guard let host = hosts.first(where: { $0.id == hostId }) else {
            throw RemoteSessionError.invalidConfiguration("Remote host no longer exists")
        }

        do {
            let response = try await connection.resumeThread(threadId: threadId, turnContext: nil)
            let thread = response.thread
            markStateChanged()
            hostActionErrors.removeValue(forKey: hostId)
            let logicalSessionId = logicalSessionId(
                sshTarget: host.sshTarget,
                cwd: thread.cwd
            )
            setPreferredThreadBinding(
                logicalSessionId: logicalSessionId,
                threadId: thread.id,
                reason: "open-thread"
            )
            upsertRawThread(hostId: hostId, thread: thread)
            refreshVisibleLogicalSession(hostId: hostId, logicalSessionId: logicalSessionId)
            updateTurnContextSnapshot(
                hostId: hostId,
                threadId: thread.id,
                snapshot: turnContext(from: response)
            )
            await logMonitorEvent(
                level: .info,
                hostId: hostId,
                method: "thread/resume",
                threadId: thread.id,
                message: "Opened remote thread",
                payload: "logicalSessionId=\(logicalSessionId) rawStatus=\(thread.status)"
            )
            Task {
                try? await connection.refreshThreads()
            }
            guard let state = threadState(hostId: hostId, threadId: thread.id) else {
                throw RemoteSessionError.missingThread
            }
            if state.turnContext.collaborationMode?.mode == .plan,
               state.phase == .waitingForInput,
               state.primaryPendingInteraction == nil {
                let recentHistory = state.history.suffix(4).map { item -> String in
                    switch item.type {
                    case .user:
                        return "user:\(item.id)"
                    case .assistant:
                        return "assistant:\(item.id)"
                    case .userImage:
                        return "userImage:\(item.id)"
                    case .assistantImage:
                        return "assistantImage:\(item.id)"
                    case .thinking:
                        return "thinking:\(item.id)"
                    case .toolCall(let tool):
                        return "tool:\(tool.name):\(item.id)"
                    case .interrupted:
                        return "interrupted:\(item.id)"
                    }
                }.joined(separator: ",")
                await logMonitorEvent(
                    level: .warning,
                    hostId: hostId,
                    method: "thread/resume",
                    threadId: state.threadId,
                    turnId: state.activeTurnId,
                    message: "Resumed remote plan thread without pending interaction",
                    payload: "phase=\(state.phase.description) canSend=\(state.canSendMessage) historyTail=[\(recentHistory)]"
                )
            }
            scheduleFollowUpRefresh(
                hostId: hostId,
                connection: connection,
                reason: "thread/resume",
                threadId: thread.id,
                surfaceErrorToUser: true
            )
            return state
        } catch {
            let presentableError = presentableRemoteError(error, hostId: hostId)
            markStateChanged()
            hostActionErrors[hostId] = presentableError.localizedDescription
            await logMonitorEvent(
                level: .error,
                hostId: hostId,
                method: "thread/resume",
                threadId: threadId,
                message: "Failed to open remote thread",
                payload: presentableError.localizedDescription
            )
            throw presentableError
        }
    }

    func sendMessage(thread: RemoteThreadState, text: String) async throws {
        guard let connection = connections[thread.hostId] else {
            throw connectionAvailabilityError(hostId: thread.hostId)
        }
        let optimisticItemId = appendOptimisticUserMessage(thread: thread, text: text)
        defer {
            refreshHost(id: thread.hostId)
        }
        do {
            try await connection.sendMessage(
                threadId: thread.threadId,
                text: text,
                activeTurnId: thread.canSteerTurn ? thread.activeTurnId : nil,
                turnContext: thread.turnContext
            )
            if !thread.canSteerTurn {
                updateTurnContextSnapshot(
                    hostId: thread.hostId,
                    threadId: thread.threadId,
                    snapshot: thread.turnContext
                )
            }
            await logMonitorEvent(
                level: .info,
                hostId: thread.hostId,
                method: thread.canSteerTurn ? "turn/steer" : "turn/start",
                threadId: thread.threadId,
                turnId: thread.activeTurnId,
                message: "Sent remote user message",
                payload: text
            )
        } catch {
            if case .timeout = (error as? RemoteSessionError) {
                await logMonitorEvent(
                    level: .warning,
                    hostId: thread.hostId,
                    method: thread.canSteerTurn ? "turn/steer" : "turn/start",
                    threadId: thread.threadId,
                    turnId: thread.activeTurnId,
                    message: "Remote message send timed out; awaiting async events",
                    payload: text
                )
                return
            }
            let presentableError = presentableRemoteError(error, hostId: thread.hostId)
            removeOptimisticUserMessage(
                hostId: thread.hostId,
                threadId: thread.threadId,
                localId: optimisticItemId
            )
            await logMonitorEvent(
                level: .error,
                hostId: thread.hostId,
                method: thread.canSteerTurn ? "turn/steer" : "turn/start",
                threadId: thread.threadId,
                turnId: thread.activeTurnId,
                message: "Remote message send failed",
                payload: presentableError.localizedDescription
            )
            throw presentableError
        }
    }

    func setTurnContext(
        thread: RemoteThreadState,
        turnContext desiredTurnContext: RemoteThreadTurnContext,
        synchronizeThread: Bool
    ) async throws -> RemoteThreadState {
        if synchronizeThread {
            guard let connection = connections[thread.hostId] else {
                throw RemoteSessionError.notConnected
            }
            let response = try await connection.resumeThread(
                threadId: thread.threadId,
                turnContext: desiredTurnContext
            )
            let resumedThread = response.thread
            markStateChanged()
            apply(event: .threadUpsert(hostId: thread.hostId, thread: resumedThread))
            updateTurnContextSnapshot(
                hostId: thread.hostId,
                threadId: resumedThread.id,
                snapshot: mergeTurnContext(
                    base: turnContext(from: response),
                    overridingWith: desiredTurnContext
                )
            )
            guard let state = threads.first(where: {
                $0.hostId == thread.hostId && $0.threadId == resumedThread.id
            }) else {
                throw RemoteSessionError.missingThread
            }
            return state
        }

        updateTurnContextSnapshot(
            hostId: thread.hostId,
            threadId: thread.threadId,
            snapshot: desiredTurnContext
        )
        guard let state = threads.first(where: {
            $0.hostId == thread.hostId && $0.threadId == thread.threadId
        }) else {
            throw RemoteSessionError.missingThread
        }
        return state
    }

    func interrupt(thread: RemoteThreadState) async throws {
        guard let connection = connections[thread.hostId] else {
            throw RemoteSessionError.notConnected
        }
        guard let activeTurnId = thread.activeTurnId else {
            return
        }
        try await connection.interrupt(threadId: thread.threadId, turnId: activeTurnId)
    }

    func approve(thread: RemoteThreadState) async throws {
        try await respond(thread: thread, action: .allow)
    }

    func deny(thread: RemoteThreadState) async throws {
        try await respond(thread: thread, action: .deny)
    }

    func respond(thread: RemoteThreadState, action: PendingApprovalAction) async throws {
        guard let approval = thread.pendingApproval else { return }
        guard let connection = connections[thread.hostId] else {
            throw RemoteSessionError.notConnected
        }

        try await connection.respond(to: approval, action: action)
        clearPendingApproval(hostId: thread.hostId, threadId: thread.threadId, itemId: approval.itemId)
    }

    func respond(
        thread: RemoteThreadState,
        interaction: PendingUserInputInteraction,
        answers: PendingInteractionAnswerPayload
    ) async throws {
        guard let connection = connections[thread.hostId] else {
            throw RemoteSessionError.notConnected
        }

        try await connection.respond(to: interaction, answers: answers)
        clearPendingInteraction(hostId: thread.hostId, threadId: thread.threadId, interactionId: interaction.id)
    }

    private func persistHosts() {
        saveHosts(hosts)
        syncConnections()
    }

    private func syncConnections() {
        let enabledHosts = Dictionary(
            uniqueKeysWithValues: hosts.filter(\.isEnabled).map { ($0.id, $0) }
        )

        for (id, connection) in connections where enabledHosts[id] == nil {
            Task { await connection.stop() }
            connections.removeValue(forKey: id)
            resetHostRuntimeState(hostId: id, clearConnectionState: true)
        }

        for (id, host) in enabledHosts {
            if let connection = connections[id] {
                Task { await connection.updateHost(host) }
            } else {
                let weakSelf = self
                let connection = connectionFactory(host) { event in
                    await MainActor.run {
                        weakSelf.apply(event: event)
                    }
                }
                connections[id] = connection
                Task { await connection.start() }
            }
            resolveThreadFilter(for: host)
        }
    }

    func apply(event: RemoteConnectionEvent) {
        markStateChanged()
        switch event {
        case .connectionState(let hostId, let state):
            hostStates[hostId] = state
            switch state {
            case .connected:
                hostActionErrors.removeValue(forKey: hostId)
            case .failed(let message):
                if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    hostActionErrors[hostId] = message
                }
            case .connecting, .disconnected:
                break
            }
            for index in threads.indices where threads[index].hostId == hostId {
                threads[index].connectionState = state
            }

        case .threadList(let hostId, let remoteThreads):
            applyThreadList(hostId: hostId, remoteThreads: remoteThreads)

        case .threadUpsert(let hostId, let thread):
            upsertRawThread(hostId: hostId, thread: thread)
            let logicalSessionId = logicalSessionId(
                sshTarget: hosts.first(where: { $0.id == hostId })?.sshTarget ?? "",
                cwd: thread.cwd
            )
            refreshVisibleLogicalSession(hostId: hostId, logicalSessionId: logicalSessionId)

        case .threadStatusChanged(let hostId, let threadId, let status):
            guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
            threads[index].phase = phase(
                from: status,
                pendingApproval: threads[index].pendingApproval,
                activeTurnId: threads[index].activeTurnId
            )
            threads[index].isLoaded = status != .notLoaded
            threads[index].updatedAt = Date()
            threads[index].lastActivity = Date()

        case .turnStarted(let hostId, let threadId, let turn):
            guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
            threads[index].activeTurnId = turn.id
            threads[index].canSteerTurn = true
            threads[index].phase = .processing
            threads[index].updatedAt = Date()
            threads[index].lastActivity = Date()

        case .turnCompleted(let hostId, let threadId, let turn):
            guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
            upsertTurnItems(turn.items, threadIndex: index, isCompletion: true)
            threads[index].activeTurnId = nil
            threads[index].canSteerTurn = false
            threads[index].pendingApproval = nil
            threads[index].pendingInteractions.removeAll()
            threads[index].phase = phase(from: turn.status)
            threads[index].updatedAt = Date()
            threads[index].lastActivity = Date()

        case .turnPlanUpdated(let hostId, let threadId, let turnId, let explanation, let plan):
            guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
            upsertPlanUpdate(
                threadIndex: index,
                turnId: turnId,
                explanation: explanation,
                plan: plan
            )

        case .tokenUsageUpdated(let hostId, let threadId, _, let tokenUsage):
            updateTokenUsageSnapshot(
                hostId: hostId,
                threadId: threadId,
                tokenUsage: tokenUsage
            )

        case .itemStarted(let hostId, let threadId, _, let item):
            guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
            upsertHistoryItem(item, threadIndex: index, isCompletion: false)

        case .itemCompleted(let hostId, let threadId, _, let item):
            guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
            upsertHistoryItem(item, threadIndex: index, isCompletion: true)
            clearPendingApproval(hostId: hostId, threadId: threadId, itemId: item.id)
            clearPendingInteraction(hostId: hostId, threadId: threadId, interactionId: item.id)

        case .agentMessageDelta(let hostId, let threadId, _, let itemId, let delta):
            guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
            appendAssistantDelta(threadIndex: index, itemId: itemId, delta: delta)

        case .approval(let hostId, let threadId, let approval):
            guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
            threads[index].pendingApproval = approval
            upsertPendingInteraction(
                hostId: hostId,
                threadId: threadId,
                interaction: .approval(PendingApprovalInteraction(
                    id: approval.itemId,
                    title: approval.title,
                    kind: approval.pendingKind,
                    detail: approval.detail,
                    requestedPermissions: approval.requestedPermissions,
                    availableActions: approval.availableActions,
                    transport: .remoteAppServer(requestId: approval.requestId)
                ))
            )
            threads[index].phase = .waitingForApproval(PermissionContext(
                toolUseId: approval.itemId,
                toolName: approval.title,
                toolInput: nil,
                receivedAt: Date()
            ))
            threads[index].updatedAt = Date()
            threads[index].lastActivity = Date()

        case .userInputRequest(let hostId, let threadId, let interaction):
            upsertPendingInteraction(hostId: hostId, threadId: threadId, interaction: .userInput(interaction))

        case .serverRequestResolved(let hostId, let threadId, let requestId):
            clearPendingInteraction(hostId: hostId, threadId: threadId, requestId: requestId)

        case .threadError(let hostId, let threadId, let turnId, let message, let willRetry):
            guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
            threads[index].history.append(ChatHistoryItem(
                id: "remote-error-\(turnId ?? UUID().uuidString)-\(Date().timeIntervalSince1970)",
                type: .assistant(message),
                timestamp: Date()
            ))
            threads[index].lastActivity = Date()
            threads[index].updatedAt = Date()
            if !willRetry {
                threads[index].activeTurnId = nil
                threads[index].canSteerTurn = false
                threads[index].pendingApproval = nil
                threads[index].pendingInteractions.removeAll()
                threads[index].phase = .idle
            }
            updateDerivedFields(at: index)
        }
    }

    private func applyThreadList(hostId: String, remoteThreads: [RemoteAppServerThread]) {
        let host = hosts.first(where: { $0.id == hostId })
        let rawSummary = remoteThreads.map(rawThreadSummary).joined(separator: " | ")
        Task {
            await self.logMonitorEvent(
                level: .debug,
                hostId: hostId,
                method: "thread/list",
                message: "Applied remote raw thread list",
                payload: "count=\(remoteThreads.count) threads=[\(rawSummary)]"
            )
        }
        let retainedThreads = retainedPreferredThreads(
            hostId: hostId,
            host: host,
            remoteThreads: remoteThreads
        )
        replaceRawThreads(hostId: hostId, with: remoteThreads, retaining: retainedThreads)
        let visibleThreads = rawThreads(hostId: hostId).filter { shouldDisplayThread($0, for: host) }
        // Multiple raw threads from the same host/cwd collapse into one logical
        // session. The rest of the monitor works on that logical layer so the
        // notch shows one entry per workspace instead of every historic thread.
        let groupedThreads = Dictionary(grouping: visibleThreads) { thread in
            logicalSessionId(
                sshTarget: host?.sshTarget ?? "",
                cwd: thread.cwd
            )
        }

        let survivingLogicalIds = Set(groupedThreads.keys)
        let survivingThreadIds = Set(visibleThreads.map(\.id))
        threads.removeAll { $0.hostId == hostId && !survivingLogicalIds.contains($0.logicalSessionId) }
        optimisticUserMessages.removeAll {
            $0.hostId == hostId && !survivingThreadIds.contains($0.threadId)
        }

        for logicalSessionId in groupedThreads.keys {
            refreshVisibleLogicalSession(hostId: hostId, logicalSessionId: logicalSessionId)
        }
    }

    private func refreshVisibleLogicalSession(hostId: String, logicalSessionId: String) {
        let host = hosts.first(where: { $0.id == hostId })
        let visibleCandidates = rawThreads(hostId: hostId).filter { thread in
            shouldDisplayThread(thread, for: host) &&
                self.logicalSessionId(
                    sshTarget: host?.sshTarget ?? "",
                    cwd: thread.cwd
                ) == logicalSessionId
        }

        guard !visibleCandidates.isEmpty else {
            clearPreferredThreadBinding(logicalSessionId: logicalSessionId)
            threads.removeAll { $0.hostId == hostId && $0.logicalSessionId == logicalSessionId }
            return
        }

        let selectedThread: RemoteAppServerThread
        if let preferredThreadId = preferredThreadBindings[logicalSessionId],
           let preferredThread = visibleCandidates.first(where: { $0.id == preferredThreadId }) {
            selectedThread = preferredThread
        } else {
            clearPreferredThreadBinding(logicalSessionId: logicalSessionId)
            // Without a preferred binding we pick the most active/recent raw
            // thread so reconnects and refreshes naturally bias toward the
            // currently "live" conversation for that cwd.
            guard let latestThread = latestThread(from: visibleCandidates) else { return }
            selectedThread = latestThread
        }

        let selectedPhase = inferredVisiblePhase(for: selectedThread)
        let hasCompetingCandidates = visibleCandidates.count > 1
        let preferredThreadId = preferredThreadBindings[logicalSessionId]
        if hasCompetingCandidates || selectedPhase == .idle {
            let candidateSummary = visibleCandidates
                .sorted { lhs, rhs in
                    let lhsPriority = visibleThreadPriority(for: lhs)
                    let rhsPriority = visibleThreadPriority(for: rhs)
                    if lhsPriority != rhsPriority {
                        return lhsPriority > rhsPriority
                    }
                    if lhs.updatedAt != rhs.updatedAt {
                        return lhs.updatedAt > rhs.updatedAt
                    }
                    return lhs.createdAt > rhs.createdAt
                }
                .map(visibleThreadCandidateSummary)
                .joined(separator: " | ")

            Task {
                await self.logMonitorEvent(
                    level: .debug,
                    hostId: hostId,
                    threadId: selectedThread.id,
                    message: "Resolved visible remote thread",
                    payload: "logicalSessionId=\(logicalSessionId) preferred=\(preferredThreadId ?? "-") selected=\(selectedThread.id) selectedPhase=\(selectedPhase.description) candidates=[\(candidateSummary)]"
                )
            }
        }

        upsertVisibleThread(
            hostId: hostId,
            thread: selectedThread,
            replaceHistory: !selectedThread.turns.isEmpty
        )
    }

    private func upsertVisibleThread(hostId: String, thread: RemoteAppServerThread, replaceHistory: Bool) {
        let host = hosts.first(where: { $0.id == hostId })
        guard shouldDisplayThread(thread, for: host) else { return }
        let hostName = host?.displayName ?? "Remote Host"
        let connectionState = hostStates[hostId] ?? .disconnected
        let computedHistory = replaceHistory ? RemoteThreadHistoryMapper.historyItems(from: thread.turns) : nil
        let computedTurn = RemoteThreadHistoryMapper.activeTurn(from: thread.turns)
        let logicalSessionId = logicalSessionId(
            sshTarget: host?.sshTarget ?? "",
            cwd: thread.cwd
        )

        if let index = threadIndex(logicalSessionId: logicalSessionId) {
            let isRebindingRawThread = threads[index].threadId != thread.id
            let previousThreadId = threads[index].threadId
            let previousPhase = threads[index].phase
            let previousUpdatedAt = threads[index].updatedAt
            let previousPendingInteraction = threads[index].primaryPendingInteraction
            let previousPendingApproval = isRebindingRawThread ? nil : threads[index].pendingApproval
            threads[index].preview = thread.preview
            threads[index].name = thread.name
            threads[index].logicalSessionId = logicalSessionId
            threads[index].cwd = thread.cwd
            threads[index].threadId = thread.id
            threads[index].updatedAt = remoteDate(thread.updatedAt)
            threads[index].createdAt = remoteDate(thread.createdAt)
            threads[index].isLoaded = thread.status != .notLoaded
            threads[index].connectionState = connectionState

            if let computedHistory {
                // A loaded thread snapshot replaces history wholesale because
                // turns from the server are authoritative and already ordered.
                // Optimistic local messages are cleared once the real turn list
                // arrives for that raw thread id.
                threads[index].history = computedHistory
                threads[index].activeTurnId = computedTurn?.id
                threads[index].canSteerTurn = computedTurn != nil
                optimisticUserMessages.removeAll {
                    $0.hostId == hostId && $0.threadId == thread.id
                }
                if isRebindingRawThread {
                    threads[index].pendingApproval = nil
                    threads[index].pendingInteractions.removeAll()
                    threads[index].tokenUsage = nil
                    optimisticUserMessages.removeAll {
                        $0.hostId == hostId && $0.threadId == previousThreadId
                    }
                }
            } else if isRebindingRawThread {
                threads[index].history = []
                threads[index].activeTurnId = computedTurn?.id
                threads[index].canSteerTurn = computedTurn != nil
                threads[index].pendingApproval = nil
                threads[index].pendingInteractions.removeAll()
                threads[index].tokenUsage = nil
                optimisticUserMessages.removeAll {
                    $0.hostId == hostId && $0.threadId == previousThreadId
                }
            }

            updateDerivedFields(at: index)
            let nextPhase = phase(
                from: thread.status,
                pendingApproval: previousPendingApproval ?? threads[index].pendingApproval,
                activeTurnId: threads[index].activeTurnId
            )
            if shouldPreserveVisiblePhase(
                currentPhase: previousPhase,
                currentUpdatedAt: previousUpdatedAt,
                currentPendingInteraction: previousPendingInteraction,
                incomingPhase: nextPhase,
                thread: thread,
                isRebindingRawThread: isRebindingRawThread
            ) {
                threads[index].phase = previousPhase
                Task {
                    await self.logMonitorEvent(
                        level: .debug,
                        hostId: hostId,
                        method: "thread/list",
                        threadId: thread.id,
                        message: "Preserved richer remote phase over weak raw snapshot",
                        payload: "currentPhase=\(previousPhase.description) incomingPhase=\(nextPhase.description) status=\(thread.status) updatedAt=\(thread.updatedAt)"
                    )
                }
            } else {
                threads[index].phase = nextPhase
            }
            scheduleTranscriptFallbackSync(hostId: hostId, thread: thread)
            return
        }

        let state = RemoteThreadState(
            hostId: hostId,
            hostName: hostName,
            threadId: thread.id,
            logicalSessionId: logicalSessionId,
            preview: thread.preview,
            name: thread.name,
            cwd: thread.cwd,
            phase: initialVisiblePhase(
                for: thread,
                activeTurnId: computedTurn?.id
            ),
            lastActivity: remoteDate(thread.updatedAt),
            createdAt: remoteDate(thread.createdAt),
            updatedAt: remoteDate(thread.updatedAt),
            lastMessage: nil,
            lastMessageRole: nil,
            lastToolName: nil,
            lastUserMessageDate: nil,
            history: computedHistory ?? [],
            activeTurnId: computedTurn?.id,
            isLoaded: thread.status != .notLoaded,
            canSteerTurn: computedTurn != nil,
            pendingApproval: nil,
            pendingInteractions: [],
            connectionState: connectionState,
            turnContext: .empty,
            tokenUsage: nil
        )

        threads.append(state)
        if let index = threadIndex(logicalSessionId: logicalSessionId) {
            updateDerivedFields(at: index)
        }
        if state.phase == .processing && thread.status == .idle && thread.turns.isEmpty {
            Task {
                await self.logMonitorEvent(
                    level: .debug,
                    hostId: hostId,
                    method: "thread/list",
                    threadId: thread.id,
                    message: "Assigned provisional busy phase while transcript fallback resolves",
                    payload: "status=\(thread.status) updatedAt=\(thread.updatedAt) path=\(thread.path ?? "-")"
                )
            }
        }
        scheduleTranscriptFallbackSync(hostId: hostId, thread: thread)
    }

    private func initialVisiblePhase(
        for thread: RemoteAppServerThread,
        activeTurnId: String?
    ) -> SessionPhase {
        let rawPhase = phase(from: thread.status, pendingApproval: nil, activeTurnId: activeTurnId)
        guard rawPhase == .idle else { return rawPhase }
        guard activeTurnId == nil else { return rawPhase }
        guard thread.turns.isEmpty else { return rawPhase }
        guard let path = thread.path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return rawPhase
        }

        let updatedAt = remoteDate(thread.updatedAt)
        guard Date().timeIntervalSince(updatedAt) <= transcriptFallbackProvisionalBusyWindow else {
            return rawPhase
        }

        return .processing
    }

    private func shouldPreserveVisiblePhase(
        currentPhase: SessionPhase,
        currentUpdatedAt: Date,
        currentPendingInteraction: PendingInteraction?,
        incomingPhase: SessionPhase,
        thread: RemoteAppServerThread,
        isRebindingRawThread: Bool
    ) -> Bool {
        guard !isRebindingRawThread else { return false }
        guard incomingPhase == .idle else { return false }
        guard thread.turns.isEmpty else { return false }

        let currentNeedsProtection =
            currentPhase.isActive ||
            currentPhase.isWaitingForApproval ||
            currentPhase == .waitingForInput ||
            currentPendingInteraction != nil
        guard currentNeedsProtection else { return false }

        // app-server may briefly replay an outdated idle/notLoaded snapshot right after attach.
        // Keep the richer state for a short settling window so transcript fallback and live events
        // can converge without flickering the UI between idle and active.
        return Date().timeIntervalSince(currentUpdatedAt) < 2
    }

    private func scheduleTranscriptFallbackSync(hostId: String, thread: RemoteAppServerThread) {
        guard let transcriptPath = thread.path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !transcriptPath.isEmpty else {
            Task {
                await self.logMonitorEvent(
                    level: .debug,
                    hostId: hostId,
                    method: "transcript-fallback",
                    threadId: thread.id,
                    message: "Skipped transcript fallback sync",
                    payload: "reason=no-transcript-path"
                )
            }
            return
        }

        guard let connection = connections[hostId] else {
            Task {
                await self.logMonitorEvent(
                    level: .debug,
                    hostId: hostId,
                    method: "transcript-fallback",
                    threadId: thread.id,
                    message: "Skipped transcript fallback sync",
                    payload: "reason=no-connection path=\(transcriptPath)"
                )
            }
            return
        }

        let inferredPhase = inferredVisiblePhase(for: thread)
        // Transcript fallback is only used for idle/waiting threads where the
        // raw thread list may lag behind richer transcript state such as plan
        // follow-up prompts or pending interactions.
        let shouldSync = inferredPhase == .idle || inferredPhase == .waitingForInput
        guard shouldSync else {
            Task {
                await self.logMonitorEvent(
                    level: .debug,
                    hostId: hostId,
                    method: "transcript-fallback",
                    threadId: thread.id,
                    message: "Skipped transcript fallback sync",
                    payload: "reason=phase-not-eligible phase=\(inferredPhase.description) path=\(transcriptPath)"
                )
            }
            return
        }

        let key = "\(hostId):\(thread.id)"
        if let existingTask = transcriptSyncTasks[key] {
            existingTask.cancel()
            transcriptSyncTasks.removeValue(forKey: key)
            Task {
                await self.logMonitorEvent(
                    level: .debug,
                    hostId: hostId,
                    method: "transcript-fallback",
                    threadId: thread.id,
                    message: "Restarting transcript fallback sync",
                    payload: "phase=\(inferredPhase.description) path=\(transcriptPath)"
                )
            }
        }

        transcriptSyncTasks[key] = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.transcriptSyncTasks.removeValue(forKey: key)
                }
            }

            let maxBytes = self?.transcriptFallbackMaxBytes ?? 256 * 1024
            let sshTimeout = self?.transcriptFallbackSSHTimeout ?? .seconds(8)
            let parseTimeout = self?.transcriptFallbackParseTimeout ?? .seconds(2)
            let applyTimeout = self?.transcriptFallbackApplyTimeout ?? .seconds(1)

            await self?.logMonitorEvent(
                level: .debug,
                hostId: hostId,
                method: "transcript-fallback",
                threadId: thread.id,
                message: "Scheduled transcript fallback sync",
                payload: "phase=\(inferredPhase.description) path=\(transcriptPath)"
            )

            do {
                let content = try await self?.runTranscriptFallbackStep(
                    hostId: hostId,
                    threadId: thread.id,
                    stage: "ssh-tail",
                    timeout: sshTimeout,
                    startPayload: "path=\(transcriptPath) maxBytes=\(maxBytes)",
                    successPayload: { content in
                        let byteCount = content?.lengthOfBytes(using: .utf8) ?? 0
                        return "path=\(transcriptPath) bytes=\(byteCount)"
                    }
                ) {
                    try await connection.loadTranscriptFallbackContent(
                        transcriptPath: transcriptPath,
                        maxBytes: maxBytes
                    )
                }

                guard let content,
                      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    await self?.logMonitorEvent(
                        level: .debug,
                        hostId: hostId,
                        method: "transcript-fallback",
                        threadId: thread.id,
                        message: "Loaded transcript fallback snapshot",
                        payload: "snapshot=nil"
                    )
                    return
                }

                let parsed = try await self?.runTranscriptFallbackStep(
                    hostId: hostId,
                    threadId: thread.id,
                    stage: "parser",
                    timeout: parseTimeout,
                    startPayload: "path=\(transcriptPath)",
                    successPayload: { parsed in
                        "phase=\(parsed.transcriptPhase?.description ?? "nil") pending=\(parsed.pendingInteractions.count) history=\(parsed.history.count)"
                    }
                ) {
                    await CodexConversationParser.shared.parseContent(sessionId: thread.id, content: content)
                }

                guard let parsed else { return }

                let snapshot = RemoteTranscriptFallbackSnapshot(
                    history: parsed.history,
                    pendingInteractions: parsed.pendingInteractions,
                    transcriptPhase: parsed.transcriptPhase,
                    runtimeInfo: parsed.runtimeInfo
                )
                await self?.logMonitorEvent(
                    level: .debug,
                    hostId: hostId,
                    method: "transcript-fallback",
                    threadId: thread.id,
                    message: "Loaded transcript fallback snapshot",
                    payload: "phase=\(snapshot.transcriptPhase?.description ?? "nil") pending=\(snapshot.pendingInteractions.count) history=\(snapshot.history.count)"
                )

                _ = try await self?.runTranscriptFallbackStep(
                    hostId: hostId,
                    threadId: thread.id,
                    stage: "apply",
                    timeout: applyTimeout,
                    startPayload: "phase=\(snapshot.transcriptPhase?.description ?? "nil") pending=\(snapshot.pendingInteractions.count) history=\(snapshot.history.count)",
                    successPayload: { _ in
                        "threadId=\(thread.id)"
                    }
                ) {
                    await MainActor.run {
                        self?.applyTranscriptFallback(hostId: hostId, threadId: thread.id, snapshot: snapshot)
                    }
                }
            } catch {
                await self?.logMonitorEvent(
                    level: .warning,
                    hostId: hostId,
                    method: "transcript-fallback",
                    threadId: thread.id,
                    message: "Failed to load remote transcript fallback snapshot",
                    payload: error.localizedDescription
                )
            }
        }
    }

    private func runTranscriptFallbackStep<T: Sendable>(
        hostId: String,
        threadId: String,
        stage: String,
        timeout: Duration,
        startPayload: String? = nil,
        successPayload: ((T) -> String?)? = nil,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        await logMonitorEvent(
            level: .debug,
            hostId: hostId,
            method: "transcript-fallback",
            threadId: threadId,
            message: "Started transcript fallback \(stage)",
            payload: startPayload
        )

        do {
            let result = try await withTimeout(
                timeout,
                errorMessage: "Timed out waiting for transcript fallback \(stage)"
            ) {
                try await operation()
            }

            await logMonitorEvent(
                level: .debug,
                hostId: hostId,
                method: "transcript-fallback",
                threadId: threadId,
                message: "Completed transcript fallback \(stage)",
                payload: successPayload?(result)
            )
            return result
        } catch {
            if case .timeout = error as? RemoteSessionError {
                await logMonitorEvent(
                    level: .warning,
                    hostId: hostId,
                    method: "transcript-fallback",
                    threadId: threadId,
                    message: "Timed out transcript fallback \(stage)",
                    payload: error.localizedDescription
                )
            }
            throw error
        }
    }

    private func applyTranscriptFallback(
        hostId: String,
        threadId: String,
        snapshot: RemoteTranscriptFallbackSnapshot?
    ) {
        guard let snapshot,
              let index = threadIndex(hostId: hostId, threadId: threadId) else {
            return
        }

        let currentPhase = threads[index].phase
        let transcriptPhase = snapshot.transcriptPhase
        // Transcript fallback is allowed to promote an idle thread into a more
        // descriptive waiting state, but it should not stomp active live state
        // unless the current view is effectively idle or waiting for a plan reply.
        let shouldOverridePhase = transcriptPhase != nil && (
            currentPhase == .idle ||
                (threads[index].turnContext.collaborationMode?.mode == .plan &&
                    threads[index].primaryPendingInteraction == nil)
        )

        if !snapshot.pendingInteractions.isEmpty {
            threads[index].pendingInteractions = snapshot.pendingInteractions
        }

        if let transcriptPhase, shouldOverridePhase {
            threads[index].phase = transcriptPhase
        }

        let shouldReplaceHistory =
            !snapshot.history.isEmpty &&
            (threads[index].history.isEmpty ||
                !snapshot.pendingInteractions.isEmpty ||
                (threads[index].turnContext.collaborationMode?.mode == .plan && currentPhase == .idle))

        if shouldReplaceHistory {
            threads[index].history = snapshot.history
            updateDerivedFields(at: index)
        }

        if threads[index].primaryPendingInteraction != nil || shouldOverridePhase {
            threads[index].updatedAt = Date()
            threads[index].lastActivity = Date()
        }

        Task {
            await self.logMonitorEvent(
                level: .debug,
                hostId: hostId,
                method: "transcript-fallback",
                threadId: threadId,
                message: "Applied transcript fallback snapshot",
                payload: "beforePhase=\(currentPhase.description) transcriptPhase=\(transcriptPhase?.description ?? "nil") afterPhase=\(threads[index].phase.description) pending=\(threads[index].pendingInteractions.count) canSend=\(threads[index].canSendMessage) history=\(threads[index].history.count)"
            )
        }
    }

    private func updateDerivedFields(at index: Int) {
        let history = threads[index].history
        threads[index].lastMessage = nil
        threads[index].lastMessageRole = nil
        threads[index].lastToolName = nil
        threads[index].lastUserMessageDate = nil

        for item in history.reversed() {
            switch item.type {
            case .assistant(let text):
                if threads[index].lastMessage == nil {
                    threads[index].lastMessage = text
                    threads[index].lastMessageRole = "assistant"
                }
            case .assistantImage:
                if threads[index].lastMessage == nil {
                    threads[index].lastMessage = "Image"
                    threads[index].lastMessageRole = "assistant"
                }
            case .user(let text):
                if threads[index].lastUserMessageDate == nil {
                    threads[index].lastUserMessageDate = item.timestamp
                }
                if threads[index].lastMessage == nil {
                    threads[index].lastMessage = text
                    threads[index].lastMessageRole = "user"
                }
            case .userImage:
                if threads[index].lastUserMessageDate == nil {
                    threads[index].lastUserMessageDate = item.timestamp
                }
                if threads[index].lastMessage == nil {
                    threads[index].lastMessage = "Image"
                    threads[index].lastMessageRole = "user"
                }
            case .toolCall(let tool):
                if threads[index].lastMessage == nil {
                    threads[index].lastMessage = tool.inputPreview
                    threads[index].lastMessageRole = "tool"
                    threads[index].lastToolName = tool.name
                }
            case .thinking(let text):
                if threads[index].lastMessage == nil {
                    threads[index].lastMessage = text
                    threads[index].lastMessageRole = "assistant"
                }
            case .interrupted:
                if threads[index].lastMessage == nil {
                    threads[index].lastMessage = "Interrupted"
                    threads[index].lastMessageRole = "assistant"
                }
            }
        }
    }

    private func updateTurnContextSnapshot(
        hostId: String,
        threadId: String,
        snapshot: RemoteThreadTurnContext
    ) {
        guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
        markStateChanged()
        threads[index].turnContext = snapshot
    }

    private func updateTokenUsageSnapshot(
        hostId: String,
        threadId: String,
        tokenUsage: SessionTokenUsageInfo
    ) {
        guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
        markStateChanged()
        threads[index].tokenUsage = tokenUsage
    }

    private func clearPendingApproval(hostId: String, threadId: String, itemId: String) {
        guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
        guard threads[index].pendingApproval?.itemId == itemId else { return }
        threads[index].pendingApproval = nil
        threads[index].pendingInteractions.removeAll { interaction in
            if case .approval(let approval) = interaction {
                return approval.id == itemId
            }
            return false
        }
        if threads[index].activeTurnId != nil {
            threads[index].phase = .processing
        } else {
            threads[index].phase = .waitingForInput
        }
    }

    private func clearPendingInteraction(hostId: String, threadId: String, interactionId: String) {
        guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
        threads[index].pendingInteractions.removeAll { $0.id == interactionId }
        if threads[index].pendingApproval?.itemId == interactionId || threads[index].pendingApproval?.id == interactionId {
            threads[index].pendingApproval = nil
        }
        if threads[index].pendingInteractions.isEmpty {
            threads[index].phase = threads[index].activeTurnId == nil ? .waitingForInput : .processing
        }
    }

    private func clearPendingInteraction(hostId: String, threadId: String, requestId: RemoteRPCID) {
        guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
        threads[index].pendingInteractions.removeAll { $0.transport == .remoteAppServer(requestId: requestId) }
        if threads[index].pendingApproval?.requestId == requestId {
            threads[index].pendingApproval = nil
        }
        if threads[index].pendingInteractions.isEmpty {
            threads[index].phase = threads[index].activeTurnId == nil ? .waitingForInput : .processing
        }
    }

    private func upsertPendingInteraction(hostId: String, threadId: String, interaction: PendingInteraction) {
        guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
        threads[index].pendingInteractions.removeAll { $0.id == interaction.id }
        threads[index].pendingInteractions.append(interaction)
        threads[index].updatedAt = Date()
        threads[index].lastActivity = Date()
    }

    private func upsertHistoryItem(_ item: RemoteAppServerThreadItem, threadIndex: Int, isCompletion: Bool) {
        let chatItems = RemoteThreadHistoryMapper.chatHistoryItems(from: item)
        guard !chatItems.isEmpty else { return }

        for chatItem in chatItems {
            if case .userMessage = item {
                mergeOptimisticUserMessageIfNeeded(item: chatItem, threadIndex: threadIndex)
            }
            if let existing = threads[threadIndex].history.firstIndex(where: { $0.id == chatItem.id }) {
                threads[threadIndex].history[existing] = ChatHistoryItem(
                    id: chatItem.id,
                    type: chatItem.type,
                    timestamp: threads[threadIndex].history[existing].timestamp
                )
            } else {
                threads[threadIndex].history.append(chatItem)
            }
        }

        if isCompletion {
            threads[threadIndex].lastActivity = Date()
            threads[threadIndex].updatedAt = Date()
        }
        updateDerivedFields(at: threadIndex)
    }

    private func upsertTurnItems(
        _ items: [RemoteAppServerThreadItem],
        threadIndex: Int,
        isCompletion: Bool
    ) {
        for item in items {
            upsertHistoryItem(item, threadIndex: threadIndex, isCompletion: isCompletion)
        }
    }

    private func appendAssistantDelta(threadIndex: Int, itemId: String, delta: String) {
        if let existing = threads[threadIndex].history.firstIndex(where: { $0.id == itemId }),
           case .assistant(let text) = threads[threadIndex].history[existing].type {
            threads[threadIndex].history[existing] = ChatHistoryItem(
                id: itemId,
                type: .assistant(text + delta),
                timestamp: threads[threadIndex].history[existing].timestamp
            )
        } else {
            threads[threadIndex].history.append(ChatHistoryItem(
                id: itemId,
                type: .assistant(delta),
                timestamp: Date()
            ))
        }

        threads[threadIndex].lastActivity = Date()
        threads[threadIndex].updatedAt = Date()
        updateDerivedFields(at: threadIndex)
    }

    private func connectionAvailabilityError(hostId: String) -> RemoteSessionError {
        switch hostStates[hostId] {
        case .failed(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return .transport(trimmed.isEmpty ? "Remote host connection failed" : trimmed)
        case .connecting:
            return .transport("Remote host is still connecting")
        case .disconnected:
            return .transport("Remote host is disconnected. Reconnect and retry.")
        case .connected:
            return .notConnected
        case nil:
            if let actionError = hostActionErrors[hostId],
               !actionError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .transport(actionError)
            }
            return .notConnected
        }
    }

    private func presentableRemoteError(_ error: Error, hostId: String) -> Error {
        guard let remoteError = error as? RemoteSessionError else { return error }
        switch remoteError {
        case .notConnected:
            return connectionAvailabilityError(hostId: hostId)
        default:
            return remoteError
        }
    }

    @discardableResult
    func appendOptimisticUserMessage(thread: RemoteThreadState, text: String) -> String {
        guard let index = threadIndex(hostId: thread.hostId, threadId: thread.threadId) else { return "" }
        let localId = "optimistic-user-\(UUID().uuidString)"
        let item = ChatHistoryItem(
            id: localId,
            type: .user(text),
            timestamp: Date()
        )
        threads[index].history.append(item)
        optimisticUserMessages.append(OptimisticRemoteUserMessage(
            localId: localId,
            hostId: thread.hostId,
            threadId: thread.threadId,
            text: text,
            createdAt: item.timestamp
        ))
        threads[index].lastActivity = Date()
        threads[index].updatedAt = Date()
        if threads[index].phase == .idle || threads[index].phase == .waitingForInput {
            threads[index].phase = .processing
        }
        updateDerivedFields(at: index)
        return localId
    }

    func availableThreads(hostId: String, excluding threadId: String? = nil) -> [RemoteThreadState] {
        rawThreads(hostId: hostId)
            .filter { thread in
                guard let excluding = threadId else { return true }
                return thread.id != excluding
            }
            .map { makeThreadCandidateState(hostId: hostId, thread: $0) }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.createdAt > rhs.createdAt
            }
    }

    func findThread(
        hostId: String,
        threadId: String? = nil,
        transcriptPath: String? = nil
    ) -> RemoteThreadState? {
        let normalizedPath = transcriptPath?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let threadId,
           let visibleThread = threadState(hostId: hostId, threadId: threadId) {
            return visibleThread
        }

        let matchedRawThread = rawThreads(hostId: hostId).first { thread in
            if let threadId, thread.id == threadId {
                return true
            }
            if let normalizedPath,
               let rawPath = thread.path?.trimmingCharacters(in: .whitespacesAndNewlines),
               !normalizedPath.isEmpty,
               rawPath == normalizedPath {
                return true
            }
            return false
        }

        guard let matchedRawThread else { return nil }
        return makeThreadCandidateState(hostId: hostId, thread: matchedRawThread)
    }

    private func makeThreadCandidateState(hostId: String, thread: RemoteAppServerThread) -> RemoteThreadState {
        if let state = threadState(hostId: hostId, threadId: thread.id) {
            return state
        }

        let host = hosts.first(where: { $0.id == hostId })
        let connectionState = hostStates[hostId] ?? .disconnected
        let computedTurn = RemoteThreadHistoryMapper.activeTurn(from: thread.turns)

        return RemoteThreadState(
            hostId: hostId,
            hostName: host?.displayName ?? "Remote Host",
            threadId: thread.id,
            logicalSessionId: logicalSessionId(
                sshTarget: host?.sshTarget ?? "",
                cwd: thread.cwd
            ),
            preview: thread.preview,
            name: thread.name,
            cwd: thread.cwd,
            phase: phase(from: thread.status, pendingApproval: nil, activeTurnId: computedTurn?.id),
            lastActivity: remoteDate(thread.updatedAt),
            createdAt: remoteDate(thread.createdAt),
            updatedAt: remoteDate(thread.updatedAt),
            lastMessage: nil,
            lastMessageRole: nil,
            lastToolName: nil,
            lastUserMessageDate: nil,
            history: [],
            activeTurnId: computedTurn?.id,
            isLoaded: thread.status != .notLoaded,
            canSteerTurn: computedTurn != nil,
            pendingApproval: nil,
            pendingInteractions: [],
            connectionState: connectionState,
            turnContext: .empty,
            tokenUsage: nil
        )
    }

    func appendLocalInfoMessage(thread: RemoteThreadState, message: String) {
        guard let index = threadIndex(hostId: thread.hostId, threadId: thread.threadId) else { return }
        markStateChanged()
        threads[index].history.append(ChatHistoryItem(
            id: "remote-local-info-\(UUID().uuidString)",
            type: .assistant(message),
            timestamp: Date()
        ))
        threads[index].updatedAt = Date()
        threads[index].lastActivity = Date()
        updateDerivedFields(at: index)
    }

    func recoverNewThread(
        hostId: String,
        excluding existingIds: Set<String>,
        pinPreferredBinding: Bool
    ) -> RemoteThreadState? {
        let newThreads = rawThreads(hostId: hostId)
            .filter { !existingIds.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.createdAt > rhs.createdAt
            }
        guard let recoveredThread = newThreads.first else { return nil }

        let host = hosts.first(where: { $0.id == hostId })
        let logicalSessionId = logicalSessionId(
            sshTarget: host?.sshTarget ?? "",
            cwd: recoveredThread.cwd
        )
        if pinPreferredBinding {
            setPreferredThreadBinding(
                logicalSessionId: logicalSessionId,
                threadId: recoveredThread.id,
                reason: "recover-new-thread"
            )
        }
        refreshVisibleLogicalSession(hostId: hostId, logicalSessionId: logicalSessionId)
        return threadState(hostId: hostId, threadId: recoveredThread.id) ??
            makeThreadCandidateState(hostId: hostId, thread: recoveredThread)
    }

    private func logMonitorEvent(
        level: RemoteDiagnosticsRecord.Level,
        hostId: String,
        method: String? = nil,
        threadId: String? = nil,
        turnId: String? = nil,
        itemId: String? = nil,
        message: String,
        payload: String? = nil
    ) async {
        let host = hosts.first(where: { $0.id == hostId })
        await diagnosticsLogger.log(
            RemoteDiagnosticsRecord(
                level: level,
                category: "remote.monitor",
                hostId: hostId,
                hostName: host?.displayName,
                sshTarget: host?.sshTarget,
                requestId: nil,
                method: method,
                threadId: threadId,
                turnId: turnId,
                itemId: itemId,
                message: message,
                payload: payload
            )
        )
    }

    private func scheduleFollowUpRefresh(
        hostId: String,
        connection: any RemoteAppServerConnectionProtocol,
        reason: String,
        threadId: String? = nil,
        surfaceErrorToUser: Bool
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await connection.refreshThreads()
                if surfaceErrorToUser {
                    self.hostActionErrors.removeValue(forKey: hostId)
                }
            } catch {
                let presentableError = self.presentableRemoteError(error, hostId: hostId)
                if surfaceErrorToUser {
                    self.hostActionErrors[hostId] = presentableError.localizedDescription
                }
                await self.logMonitorEvent(
                    level: .warning,
                    hostId: hostId,
                    method: "thread/list",
                    threadId: threadId,
                    message: "Follow-up remote refresh failed",
                    payload: "\(reason): \(presentableError.localizedDescription)"
                )
            }
        }
    }

    private func upsertPlanUpdate(
        threadIndex: Int,
        turnId: String,
        explanation: String?,
        plan: [RemoteAppServerPlanStep]
    ) {
        let itemId = "plan-update-\(turnId)"
        let todos = plan.map { step in
            TodoItem(
                content: step.step,
                status: step.status,
                activeForm: nil
            )
        }
        let summary = RemoteThreadHistoryMapper.buildPlanSummary(explanation: explanation, plan: plan)
        let planItem = ChatHistoryItem(
            id: itemId,
            type: .toolCall(ToolCallItem(
                name: "TodoWrite",
                input: explanation.flatMap { ["description": $0] } ?? [:],
                status: .success,
                result: summary,
                structuredResult: .todoWrite(TodoWriteResult(oldTodos: [], newTodos: todos)),
                subagentTools: []
            )),
            timestamp: Date()
        )

        if let existing = threads[threadIndex].history.firstIndex(where: { $0.id == itemId }) {
            threads[threadIndex].history[existing] = ChatHistoryItem(
                id: itemId,
                type: planItem.type,
                timestamp: threads[threadIndex].history[existing].timestamp
            )
        } else {
            threads[threadIndex].history.append(planItem)
        }

        threads[threadIndex].lastActivity = Date()
        threads[threadIndex].updatedAt = Date()
        updateDerivedFields(at: threadIndex)
    }

    private func mergeOptimisticUserMessageIfNeeded(item: ChatHistoryItem, threadIndex: Int) {
        guard case .user(let text) = item.type else { return }

        let hostId = threads[threadIndex].hostId
        let threadId = threads[threadIndex].threadId
        let now = Date()

        guard let optimisticMatch = optimisticUserMessages
            .filter({ optimistic in
                optimistic.hostId == hostId &&
                    optimistic.threadId == threadId &&
                    optimistic.text == text &&
                    now.timeIntervalSince(optimistic.createdAt) < 30
            })
            .sorted(by: { $0.createdAt < $1.createdAt })
            .first else {
            return
        }

        if let optimisticIndex = threads[threadIndex].history.firstIndex(where: { $0.id == optimisticMatch.localId }) {
            threads[threadIndex].history[optimisticIndex] = ChatHistoryItem(
                id: item.id,
                type: item.type,
                timestamp: threads[threadIndex].history[optimisticIndex].timestamp
            )
        }

        optimisticUserMessages.removeAll { $0.localId == optimisticMatch.localId }
    }

    private func removeOptimisticUserMessage(hostId: String, threadId: String, localId: String) {
        optimisticUserMessages.removeAll {
            $0.localId == localId || ($0.hostId == hostId && $0.threadId == threadId && $0.localId == localId)
        }
        guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
        threads[index].history.removeAll { $0.id == localId }
        updateDerivedFields(at: index)
    }

    private func turnContext(from response: RemoteAppServerThreadStartResponse) -> RemoteThreadTurnContext {
        RemoteThreadTurnContext(
            model: response.model,
            reasoningEffort: response.reasoningEffort,
            approvalPolicy: response.approvalPolicy,
            approvalsReviewer: response.approvalsReviewer,
            sandboxPolicy: response.sandbox,
            serviceTier: response.serviceTier,
            collaborationMode: response.collaborationMode
        )
    }

    private func turnContext(from response: RemoteAppServerThreadResumeResponse) -> RemoteThreadTurnContext {
        RemoteThreadTurnContext(
            model: response.model,
            reasoningEffort: response.reasoningEffort,
            approvalPolicy: response.approvalPolicy,
            approvalsReviewer: response.approvalsReviewer,
            sandboxPolicy: response.sandbox,
            serviceTier: response.serviceTier,
            collaborationMode: response.collaborationMode
        )
    }

    private func mergeTurnContext(
        base: RemoteThreadTurnContext,
        overridingWith override: RemoteThreadTurnContext
    ) -> RemoteThreadTurnContext {
        var merged = base
        merged.model = override.model ?? base.model
        merged.reasoningEffort = override.reasoningEffort ?? base.reasoningEffort
        merged.approvalPolicy = override.approvalPolicy ?? base.approvalPolicy
        merged.approvalsReviewer = override.approvalsReviewer ?? base.approvalsReviewer
        merged.sandboxPolicy = override.sandboxPolicy ?? base.sandboxPolicy
        merged.serviceTier = override.serviceTier ?? base.serviceTier
        merged.collaborationMode = override.collaborationMode ?? base.collaborationMode
        return merged
    }

    private func phase(
        from status: RemoteAppServerThreadStatus,
        pendingApproval: RemotePendingApproval?,
        activeTurnId: String?
    ) -> SessionPhase {
        if let pendingApproval {
            return .waitingForApproval(PermissionContext(
                toolUseId: pendingApproval.itemId,
                toolName: pendingApproval.title,
                toolInput: nil,
                receivedAt: Date()
            ))
        }

        switch status {
        case .notLoaded, .idle:
            return activeTurnId == nil ? .idle : .processing
        case .systemError:
            return .ended
        case .active(let activeFlags):
            if activeFlags.contains(.waitingOnApproval) {
                return .processing
            }
            if activeFlags.contains(.waitingOnUserInput) {
                return .waitingForInput
            }
            return .processing
        }
    }

    private func phase(from turnStatus: RemoteAppServerTurnStatus) -> SessionPhase {
        switch turnStatus {
        case .inProgress:
            return .processing
        case .completed, .interrupted:
            return .waitingForInput
        case .failed:
            return .idle
        }
    }

    private func remoteDate(_ timestamp: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    private func threadIndex(hostId: String, threadId: String) -> Int? {
        threads.firstIndex(where: { $0.hostId == hostId && $0.threadId == threadId })
    }
}

actor RemoteAppServerConnection: RemoteAppServerConnectionProtocol {
    private struct PendingRequestMetadata: Sendable {
        let method: String
        let threadId: String?
        let turnId: String?
        let itemId: String?
    }

    private var host: RemoteHostConfig
    private let emit: @Sendable (RemoteConnectionEvent) async -> Void
    private let dependencies: RemoteAppServerConnectionDependencies
    private let connectionId = UUID().uuidString

    private var transport: (any RemoteAppServerTransport)?
    private var refreshTask: Task<Void, Never>?
    private var remoteHomeDirectory: String?
    private var nextRequestId: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<AnyCodable?, Error>] = [:]
    private var pendingRequestMetadata: [Int: PendingRequestMetadata] = [:]
    private var latestStderr: String = ""
    private var isStopping = false
    private let requestGate = RemoteRequestSerialGate()

    init(
        host: RemoteHostConfig,
        emit: @escaping @Sendable (RemoteConnectionEvent) async -> Void,
        dependencies: RemoteAppServerConnectionDependencies = .live
    ) {
        self.host = host
        self.emit = emit
        self.dependencies = dependencies
    }

    func updateHost(_ host: RemoteHostConfig) async {
        let shouldRestart = self.host != host
        self.host = host
        if shouldRestart {
            remoteHomeDirectory = nil
            await log(
                level: .info,
                category: "remote.connection.lifecycle",
                message: "Remote host config changed; restarting connection"
            )
            await stop()
            await start()
        }
    }

    func start() async {
        guard transport == nil else { return }
        isStopping = false
        guard host.isValid else {
            await emit(.connectionState(hostId: host.id, state: .failed("SSH target required")))
            await log(
                level: .error,
                category: "remote.connection.lifecycle",
                message: "Remote host start aborted: missing SSH target"
            )
            return
        }

        await emit(.connectionState(hostId: host.id, state: .connecting))
        await log(
            level: .info,
            category: "remote.connection.lifecycle",
            message: "Starting SSH stdio transport"
        )

        let transport = dependencies.transportFactory(host)
        self.transport = transport

        do {
            try await transport.start(
                onStdoutLine: { [weak self] line in
                    await self?.handleLine(line)
                },
                onStderrLine: { [weak self] line in
                    await self?.handleStderr(line)
                },
                onTermination: { [weak self] exitCode in
                    await self?.handleTermination(exitCode: exitCode)
                }
            )
            await log(
                level: .info,
                category: "remote.connection.lifecycle",
                message: "SSH stdio transport started"
            )

            try await initialize()
            await emit(.connectionState(hostId: host.id, state: .connected))
            await log(
                level: .info,
                category: "remote.connection.lifecycle",
                message: "Remote app-server initialized"
            )
        } catch {
            self.transport = nil
            await emit(.connectionState(hostId: host.id, state: .failed(error.localizedDescription)))
            await log(
                level: .error,
                category: "remote.connection.lifecycle",
                message: "Remote connection start failed",
                payload: error.localizedDescription
            )
            await stop()
        }
    }

    func stop() async {
        guard !isStopping || transport != nil || !pendingRequests.isEmpty else { return }
        isStopping = true
        refreshTask?.cancel()
        refreshTask = nil

        await log(
            level: .info,
            category: "remote.connection.lifecycle",
            message: "Stopping remote connection"
        )

        if let transport {
            await transport.stop()
            self.transport = nil
        }

        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: RemoteSessionError.transport("Remote connection closed"))
        }
        pendingRequests.removeAll()
        pendingRequestMetadata.removeAll()
        latestStderr = ""
    }

    func normalizeCwd(_ cwd: String) async throws -> String? {
        try await normalizeRemoteCwd(cwd)
    }

    func resolveDisplayCwdFilter(_ cwd: String) async throws -> String? {
        try await resolveRemoteCwd(cwd, treatHomeAsNilPayload: false)
    }

    func startThread(defaultCwd: String) async throws -> RemoteAppServerThreadStartResponse {
        let normalizedCwd = try await normalizeRemoteCwd(defaultCwd)
        let params: [String: Any] = normalizedCwd?.isEmpty != false ? [:] : ["cwd": normalizedCwd!]
        let result = try await request(method: "thread/start", params: params)
        return try remoteDecodeValue(result ?? AnyCodable([:]), as: RemoteAppServerThreadStartResponse.self)
    }

    func resumeThread(
        threadId: String,
        turnContext: RemoteThreadTurnContext?
    ) async throws -> RemoteAppServerThreadResumeResponse {
        var params: [String: Any] = ["threadId": threadId]
        if let turnContext {
            params.merge(threadResumeParams(for: turnContext)) { _, new in new }
        }
        let result = try await request(method: "thread/resume", params: params)
        return try remoteDecodeValue(result ?? AnyCodable([:]), as: RemoteAppServerThreadResumeResponse.self)
    }

    func sendMessage(
        threadId: String,
        text: String,
        activeTurnId: String?,
        turnContext: RemoteThreadTurnContext
    ) async throws {
        if let activeTurnId {
            _ = try await request(
                method: "turn/steer",
                params: [
                    "threadId": threadId,
                    "expectedTurnId": activeTurnId,
                    "input": [["type": "text", "text": text]]
                ]
            )
            return
        }

        _ = try await request(
            method: "turn/start",
            params: [
                "threadId": threadId,
                "input": [["type": "text", "text": text]]
            ].merging(turnStartParams(for: turnContext)) { _, new in new }
        )
    }

    func interrupt(threadId: String, turnId: String) async throws {
        _ = try await request(
            method: "turn/interrupt",
            params: ["threadId": threadId, "turnId": turnId]
        )
    }

    func respond(to approval: RemotePendingApproval, allow: Bool) async throws {
        try await respond(to: approval, action: allow ? .allow : .deny)
    }

    func respond(to approval: RemotePendingApproval, action: PendingApprovalAction) async throws {
        let parser = RemoteAppServerServerRequestParser(hostId: host.id)
        let result: [String: Any]
        switch approval.kind {
        case .commandExecution, .fileChange:
            let decision: String
            switch action {
            case .allow:
                decision = "accept"
            case .allowForSession:
                decision = "acceptForSession"
            case .deny:
                decision = "decline"
            case .cancel:
                decision = "cancel"
            }
            result = ["decision": decision]
        case .permissions:
            let permissions: [String: Any]
            let scope: String
            switch action {
            case .allow:
                permissions = parser.permissionGrantPayload(from: approval.requestedPermissions)
                scope = "turn"
            case .allowForSession:
                permissions = parser.permissionGrantPayload(from: approval.requestedPermissions)
                scope = "session"
            case .deny, .cancel:
                permissions = [:]
                scope = "turn"
            }
            result = ["scope": scope, "permissions": permissions]
        }

        try await sendResponse(id: approval.requestId, result: result)
    }

    func respond(to interaction: PendingUserInputInteraction, answers: PendingInteractionAnswerPayload) async throws {
        var serializedAnswers: [String: Any] = [:]
        for (questionId, questionAnswers) in answers.answers {
            serializedAnswers[questionId] = ["answers": questionAnswers]
        }
        try await sendResponse(
            id: interaction.remoteRequestID,
            result: ["answers": serializedAnswers]
        )
    }

    func refreshThreads() async throws {
        let result = try await request(method: "thread/list", params: ["limit": 100])
        let response = try remoteDecodeValue(result ?? AnyCodable([:]), as: RemoteAppServerThreadListResponse.self)
        await emit(.threadList(hostId: host.id, threads: response.data))
    }

    func listModels(includeHidden: Bool) async throws -> [RemoteAppServerModel] {
        let result = try await request(
            method: "model/list",
            params: [
                "limit": 100,
                "includeHidden": includeHidden
            ]
        )
        let response = try remoteDecodeValue(result ?? AnyCodable([:]), as: RemoteAppServerModelListResponse.self)
        return response.data
    }

    func listCollaborationModes() async throws -> [RemoteAppServerCollaborationModeMask] {
        let result = try await request(method: "collaborationMode/list", params: [:])
        let response = try remoteDecodeValue(
            result ?? AnyCodable([:]),
            as: RemoteAppServerCollaborationModeListResponse.self
        )
        return response.data
    }

    func loadTranscriptFallbackContent(
        transcriptPath: String,
        maxBytes: Int
    ) async throws -> String? {
        let trimmedPath = transcriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }
        let byteLimit = max(64 * 1024, maxBytes)

        let content: String
        if host.sshTarget == "local-app-server" {
            guard let data = try readTrailingTranscriptBytes(path: trimmedPath, maxBytes: byteLimit),
                  let decoded = String(data: data, encoding: .utf8) else {
                return nil
            }
            content = decoded
        } else {
            let command = "tail -c \(byteLimit) -- \(shellQuoted(trimmedPath))"
            content = try await withTimeout(
                .seconds(6),
                errorMessage: "Timed out waiting for transcript fallback SSH tail"
            ) { [self] in
                try await self.dependencies.processExecutor.run("/usr/bin/ssh", arguments: [
                    "-T",
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=5",
                    self.host.sshTarget,
                    command
                ])
            }
        }

        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return content
    }

    private func readTrailingTranscriptBytes(path: String, maxBytes: Int) throws -> Data? {
        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }

        let fileSize = try handle.seekToEnd()
        let byteCount = UInt64(max(1, maxBytes))
        let startOffset = fileSize > byteCount ? fileSize - byteCount : 0
        try handle.seek(toOffset: startOffset)
        return try handle.readToEnd()
    }

    private func initialize() async throws {
        _ = try await request(
            method: "initialize",
            params: [
                "capabilities": [
                    "experimentalApi": true
                ],
                "clientInfo": [
                    "name": "codex_island",
                    "title": "Codex Island",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                ]
            ]
        )
        try await sendNotification(method: "initialized", params: nil)
    }

    private func threadResumeParams(for turnContext: RemoteThreadTurnContext) -> [String: Any] {
        var params: [String: Any] = [:]
        if let model = turnContext.model, !model.isEmpty {
            params["model"] = model
        }
        if let approvalPolicy = turnContext.approvalPolicy?.requestValue {
            params["approvalPolicy"] = approvalPolicy
        }
        if let approvalsReviewer = turnContext.approvalsReviewer {
            params["approvalsReviewer"] = approvalsReviewer.rawValue
        }
        if let sandbox = turnContext.sandboxPolicy?.sandboxMode.requestValue {
            params["sandbox"] = sandbox
        }
        if let serviceTier = turnContext.serviceTier?.rawValue {
            params["serviceTier"] = serviceTier
        }
        return params
    }

    private func turnStartParams(for turnContext: RemoteThreadTurnContext) -> [String: Any] {
        var params: [String: Any] = [:]
        if let model = turnContext.model, !model.isEmpty {
            params["model"] = model
        }
        if let effort = turnContext.reasoningEffort?.rawValue {
            params["effort"] = effort
        }
        if let approvalPolicy = turnContext.approvalPolicy?.requestValue {
            params["approvalPolicy"] = approvalPolicy
        }
        if let approvalsReviewer = turnContext.approvalsReviewer {
            params["approvalsReviewer"] = approvalsReviewer.rawValue
        }
        if let sandboxPolicy = turnContext.sandboxPolicy {
            params["sandboxPolicy"] = sandboxPolicy.requestValue
        }
        if let serviceTier = turnContext.serviceTier?.rawValue {
            params["serviceTier"] = serviceTier
        }
        if let collaborationMode = turnContext.collaborationMode {
            params["collaborationMode"] = collaborationMode.requestValue
        }
        return params
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task {
            do {
                try await self.dependencies.sleep(self.dependencies.initialRefreshDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self.refreshThreadsInBackground(reason: "initial")
            while !Task.isCancelled {
                do {
                    try await self.dependencies.sleep(self.dependencies.refreshInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.refreshThreadsInBackground(reason: "periodic")
            }
        }
    }

    func refreshThreadsInBackground(reason: String) async {
        do {
            try await refreshThreads()
            await log(
                level: .debug,
                category: "remote.connection.refresh",
                method: "thread/list",
                message: "Background thread refresh succeeded",
                payload: reason
            )
        } catch {
            await log(
                level: .warning,
                category: "remote.connection.refresh",
                method: "thread/list",
                message: "Background thread refresh failed",
                payload: "\(reason): \(error.localizedDescription)"
            )
        }
    }

    func installTransportForTesting(_ transport: any RemoteAppServerTransport) async throws {
        self.transport = transport
        try await transport.start(
            onStdoutLine: { [weak self] line in
                await self?.handleLine(line)
            },
            onStderrLine: { [weak self] line in
                await self?.handleStderr(line)
            },
            onTermination: { [weak self] exitCode in
                await self?.handleTermination(exitCode: exitCode)
            }
        )
    }

    private func handleLine(_ line: String) async {
        await log(
            level: .debug,
            category: "remote.rpc.inbound",
            message: "Received app-server line",
            payload: line
        )

        guard let data = line.data(using: .utf8) else { return }
        let decoder = JSONDecoder()

        do {
            let message = try decoder.decode(RemoteAppServerEnvelope.self, from: data)
            if let method = message.method {
                if let id = message.id {
                    await handleServerRequest(method: method, id: id, params: message.params)
                } else {
                    await handleNotification(method: method, params: message.params)
                }
                return
            }

            if case .int(let id)? = message.id,
               let continuation = pendingRequests.removeValue(forKey: id) {
                let metadata = pendingRequestMetadata.removeValue(forKey: id)
                if let error = message.error {
                    await log(
                        level: .error,
                        category: "remote.rpc.response",
                        requestId: String(id),
                        method: metadata?.method,
                        threadId: metadata?.threadId,
                        turnId: metadata?.turnId,
                        itemId: metadata?.itemId,
                        message: "Received RPC error response",
                        payload: error.message
                    )
                    continuation.resume(throwing: error)
                } else {
                    await log(
                        level: .debug,
                        category: "remote.rpc.response",
                        requestId: String(id),
                        method: metadata?.method,
                        threadId: metadata?.threadId,
                        turnId: metadata?.turnId,
                        itemId: metadata?.itemId,
                        message: "Received RPC response",
                        payload: payloadString(from: message.result)
                    )
                    continuation.resume(returning: message.result)
                }
            }
        } catch {
            await log(
                level: .error,
                category: "remote.rpc.decode",
                message: "Failed to decode app-server message",
                payload: line
            )
            await emit(.connectionState(hostId: host.id, state: .failed("Failed to decode app-server message")))
        }
    }

    private func handleNotification(method: String, params: AnyCodable?) async {
        guard let params else { return }

        do {
            switch method {
            case "thread/started":
                let payload = try remoteDecodeValue(params, as: RemoteAppServerThreadStartedNotification.self)
                await emit(.threadUpsert(hostId: host.id, thread: payload.thread))
            case "thread/status/changed":
                let payload = try remoteDecodeValue(params, as: RemoteAppServerThreadStatusChangedNotification.self)
                await emit(.threadStatusChanged(hostId: host.id, threadId: payload.threadId, status: payload.status))
            case "turn/started":
                let payload = try remoteDecodeValue(params, as: RemoteAppServerTurnStartedNotification.self)
                await emit(.turnStarted(hostId: host.id, threadId: payload.threadId, turn: payload.turn))
            case "turn/completed":
                let payload = try remoteDecodeValue(params, as: RemoteAppServerTurnCompletedNotification.self)
                await emit(.turnCompleted(hostId: host.id, threadId: payload.threadId, turn: payload.turn))
            case "turn/plan/updated":
                let payload = try remoteDecodeValue(params, as: RemoteAppServerTurnPlanUpdatedNotification.self)
                await emit(.turnPlanUpdated(
                    hostId: host.id,
                    threadId: payload.threadId,
                    turnId: payload.turnId,
                    explanation: payload.explanation,
                    plan: payload.plan
                ))
            case "thread/tokenUsage/updated":
                let payload = try remoteDecodeValue(params, as: RemoteAppServerThreadTokenUsageUpdatedNotification.self)
                await emit(.tokenUsageUpdated(
                    hostId: host.id,
                    threadId: payload.threadId,
                    turnId: payload.turnId,
                    tokenUsage: payload.tokenUsage.sessionValue
                ))
            case "item/started":
                let payload = try remoteDecodeValue(params, as: RemoteAppServerItemStartedNotification.self)
                await emit(.itemStarted(hostId: host.id, threadId: payload.threadId, turnId: payload.turnId, item: payload.item))
            case "item/completed":
                let payload = try remoteDecodeValue(params, as: RemoteAppServerItemCompletedNotification.self)
                await emit(.itemCompleted(hostId: host.id, threadId: payload.threadId, turnId: payload.turnId, item: payload.item))
            case "item/agentMessage/delta":
                let payload = try remoteDecodeValue(params, as: RemoteAppServerAgentMessageDeltaNotification.self)
                await emit(.agentMessageDelta(
                    hostId: host.id,
                    threadId: payload.threadId,
                    turnId: payload.turnId,
                    itemId: payload.itemId,
                    delta: payload.delta
                ))
            case "serverRequest/resolved":
                let payload = try remoteDecodeValue(params, as: RemoteAppServerServerRequestResolvedNotification.self)
                await emit(.serverRequestResolved(
                    hostId: host.id,
                    threadId: payload.threadId,
                    requestId: payload.requestId
                ))
            case "error":
                let payload = try remoteDecodeValue(params, as: RemoteAppServerErrorNotification.self)
                let message = payload.error.additionalDetails.map { "\(payload.error.message)\n\($0)" } ?? payload.error.message
                await log(
                    level: .error,
                    category: "remote.rpc.notification",
                    method: method,
                    threadId: payload.threadId,
                    turnId: payload.turnId,
                    message: "Received thread error notification",
                    payload: message,
                    willRetry: payload.willRetry
                )
                await emit(.threadError(
                    hostId: host.id,
                    threadId: payload.threadId,
                    turnId: payload.turnId,
                    message: message,
                    willRetry: payload.willRetry
                ))
            case "codex/event/error":
                let payload = try remoteDecodeValue(params, as: RemoteAppServerCodexEventErrorNotification.self)
                let message = payload.msg.additionalDetails.map { "\(payload.msg.message)\n\($0)" } ?? payload.msg.message
                await log(
                    level: .error,
                    category: "remote.rpc.notification",
                    method: method,
                    threadId: payload.conversationId,
                    turnId: payload.id.isEmpty ? nil : payload.id,
                    message: "Received codex event error notification",
                    payload: message
                )
                await emit(.threadError(
                    hostId: host.id,
                    threadId: payload.conversationId,
                    turnId: payload.id.isEmpty ? nil : payload.id,
                    message: message,
                    willRetry: false
                ))
            default:
                break
            }
        } catch {
            await log(
                level: .warning,
                category: "remote.rpc.notification",
                method: method,
                message: "Failed to decode notification",
                payload: payloadString(from: params)
            )
        }
    }

    private func handleServerRequest(method: String, id: RemoteRPCID, params: AnyCodable?) async {
        guard let params else { return }
        let parser = RemoteAppServerServerRequestParser(hostId: host.id)

        do {
            switch method {
            case "item/commandExecution/requestApproval":
                guard let approval = parser.commandApproval(requestId: id, params: params.value) else {
                    throw RemoteSessionError.transport("Failed to parse command approval request")
                }
                await emit(.approval(hostId: host.id, threadId: approval.threadId, approval: approval))
            case "item/fileChange/requestApproval":
                guard let approval = parser.fileApproval(requestId: id, params: params.value) else {
                    throw RemoteSessionError.transport("Failed to parse file change approval request")
                }
                await emit(.approval(hostId: host.id, threadId: approval.threadId, approval: approval))
            case "item/tool/requestUserInput":
                guard let interaction = parser.userInputRequest(requestId: id, params: params.value) else {
                    throw RemoteSessionError.transport("Failed to parse requestUserInput request")
                }
                await emit(.userInputRequest(hostId: host.id, threadId: interaction.threadId, interaction: interaction.interaction))
            case "item/permissions/requestApproval":
                guard let approval = parser.permissionsApproval(requestId: id, params: params.value) else {
                    throw RemoteSessionError.transport("Failed to parse permissions approval request")
                }
                await emit(.approval(hostId: host.id, threadId: approval.threadId, approval: approval))
            default:
                try await sendResponse(id: id, result: [:])
            }
        } catch {
            await log(
                level: .warning,
                category: "remote.rpc.server_request",
                requestId: rpcIDString(id),
                method: method,
                message: "Failed to handle server request",
                payload: error.localizedDescription
            )
        }
    }

    private func handleStderr(_ line: String) async {
        latestStderr = line.trimmingCharacters(in: .whitespacesAndNewlines)
        await log(
            level: .warning,
            category: "remote.connection.stderr",
            message: "Received stderr from SSH/app-server",
            stderr: latestStderr
        )
    }

    private func handleTermination(exitCode: Int32) async {
        if isStopping {
            await log(
                level: .info,
                category: "remote.connection.lifecycle",
                message: "Remote process terminated after local stop",
                exitCode: exitCode,
                stderr: latestStderr
            )
            return
        }

        let message: String
        if latestStderr.isEmpty {
            message = exitCode == 0 ? "Disconnected" : "SSH exited with code \(exitCode)"
        } else {
            message = latestStderr
        }

        await log(
            level: exitCode == 0 ? .warning : .error,
            category: "remote.connection.lifecycle",
            message: "Remote transport terminated unexpectedly",
            exitCode: exitCode,
            stderr: latestStderr
        )
        await emit(.connectionState(hostId: host.id, state: .failed(message)))
        await stop()
    }

    private func request(method: String, params: [String: Any]) async throws -> AnyCodable? {
        try await requestGate.withPermit {
            let id = nextRequestId
            nextRequestId += 1

            let envelope = RemoteAppServerEnvelope(
                method: method,
                id: .int(id),
                params: AnyCodable(params),
                result: nil,
                error: nil
            )
            let metadata = PendingRequestMetadata(
                method: method,
                threadId: stringValue(forKey: "threadId", in: params),
                turnId: stringValue(forKey: "turnId", in: params) ?? stringValue(forKey: "expectedTurnId", in: params),
                itemId: stringValue(forKey: "itemId", in: params)
            )

            let payload = try await sendEnvelope(envelope)
            await log(
                level: .debug,
                category: "remote.rpc.request",
                requestId: String(id),
                method: method,
                threadId: metadata.threadId,
                turnId: metadata.turnId,
                itemId: metadata.itemId,
                message: "Sent RPC request",
                payload: payload
            )

            return try await withCheckedThrowingContinuation { continuation in
                pendingRequests[id] = continuation
                pendingRequestMetadata[id] = metadata

                Task {
                    do {
                        try await self.dependencies.sleep(self.dependencies.requestTimeout)
                    } catch {
                        return
                    }
                    await self.failPendingRequest(
                        id: id,
                        error: RemoteSessionError.timeout("Timed out waiting for app-server response to \(method)")
                    )
                }
            }
        }
    }

    private func sendNotification(method: String, params: [String: Any]?) async throws {
        let envelope = RemoteAppServerEnvelope(
            method: method,
            id: nil,
            params: params.map(AnyCodable.init),
            result: nil,
            error: nil
        )
        let payload = try await sendEnvelope(envelope)
        await log(
            level: .debug,
            category: "remote.rpc.notification",
            method: method,
            message: "Sent RPC notification",
            payload: payload
        )
    }

    private func sendResponse(id: RemoteRPCID, result: [String: Any]) async throws {
        let envelope = RemoteAppServerEnvelope(
            method: nil,
            id: id,
            params: nil,
            result: AnyCodable(result),
            error: nil
        )
        let payload = try await sendEnvelope(envelope)
        await log(
            level: .debug,
            category: "remote.rpc.response",
            requestId: rpcIDString(id),
            message: "Sent RPC response",
            payload: payload
        )
    }

    private func sendEnvelope(_ envelope: RemoteAppServerEnvelope) async throws -> String {
        guard let transport else {
            throw RemoteSessionError.notConnected
        }
        let data = try JSONEncoder().encode(envelope)
        guard let line = String(data: data, encoding: .utf8) else {
            throw RemoteSessionError.transport("Failed to encode app-server message")
        }
        try await transport.send(line: line)
        return line
    }

    private func failPendingRequest(id: Int, error: Error) async {
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        let metadata = pendingRequestMetadata.removeValue(forKey: id)
        let level: RemoteDiagnosticsRecord.Level = error is RemoteSessionError ? .warning : .error
        await log(
            level: level,
            category: "remote.rpc.request",
            requestId: String(id),
            method: metadata?.method,
            threadId: metadata?.threadId,
            turnId: metadata?.turnId,
            itemId: metadata?.itemId,
            message: "Request finished with error",
            payload: error.localizedDescription
        )
        continuation.resume(throwing: error)
    }

    private func normalizeRemoteCwd(_ cwd: String) async throws -> String? {
        try await resolveRemoteCwd(cwd, treatHomeAsNilPayload: true)
    }

    private func normalizedRemoteDirectoryPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        guard standardized != "/" else { return standardized }
        return standardized.hasSuffix("/") ? standardized : standardized + "/"
    }

    private func resolveRemoteCwd(_ cwd: String, treatHomeAsNilPayload: Bool) async throws -> String? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed == "~" {
            if treatHomeAsNilPayload {
                await log(
                    level: .debug,
                    category: "remote.connection.cwd",
                    message: "Default CWD '~' resolved to nil payload"
                )
                return nil
            }

            guard let home = try await resolveRemoteHomeDirectory(), !home.isEmpty else {
                throw RemoteSessionError.invalidConfiguration("Could not resolve remote home directory for `~`")
            }
            let resolvedHome = normalizedRemoteDirectoryPath(home)
            await log(
                level: .debug,
                category: "remote.connection.cwd",
                message: "Resolved remote home directory for display filter",
                payload: "\(trimmed) -> \(resolvedHome)"
            )
            return resolvedHome
        }

        if trimmed.hasPrefix("~/") {
            guard let home = try await resolveRemoteHomeDirectory(), !home.isEmpty else {
                throw RemoteSessionError.invalidConfiguration("Could not resolve remote home directory for `~`")
            }
            let suffix = String(trimmed.dropFirst(2))
            let resolved = normalizedRemoteDirectoryPath(
                URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(suffix, isDirectory: true).path
            )
            await log(
                level: .debug,
                category: "remote.connection.cwd",
                message: "Resolved remote home directory",
                payload: "\(trimmed) -> \(resolved)"
            )
            return resolved
        }

        if trimmed.hasPrefix("/") {
            return normalizedRemoteDirectoryPath(trimmed)
        }

        return trimmed
    }

    private func resolveRemoteHomeDirectory() async throws -> String? {
        if let remoteHomeDirectory, !remoteHomeDirectory.isEmpty {
            return remoteHomeDirectory
        }

        do {
            let output = try await dependencies.processExecutor.run("/usr/bin/ssh", arguments: [
                "-T",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                host.sshTarget,
                "printf '%s' \"$HOME\""
            ])
            let home = output.trimmingCharacters(in: .whitespacesAndNewlines)
            remoteHomeDirectory = home.isEmpty ? nil : home
            await log(
                level: .debug,
                category: "remote.connection.cwd",
                message: "Resolved remote $HOME",
                payload: remoteHomeDirectory
            )
            return remoteHomeDirectory
        } catch {
            await log(
                level: .error,
                category: "remote.connection.cwd",
                message: "Failed to resolve remote $HOME",
                payload: error.localizedDescription
            )
            throw error
        }
    }

    private func stringValue(forKey key: String, in params: [String: Any]) -> String? {
        params[key] as? String
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func payloadString(from value: AnyCodable?) -> String? {
        guard let value else { return nil }
        guard let data = try? JSONEncoder().encode(value) else {
            return String(describing: value.value)
        }
        return String(data: data, encoding: .utf8)
    }

    private func rpcIDString(_ id: RemoteRPCID) -> String {
        switch id {
        case .int(let value):
            return String(value)
        case .string(let value):
            return value
        }
    }

    private func log(
        level: RemoteDiagnosticsRecord.Level,
        category: String,
        requestId: String? = nil,
        method: String? = nil,
        threadId: String? = nil,
        turnId: String? = nil,
        itemId: String? = nil,
        message: String,
        payload: String? = nil,
        exitCode: Int32? = nil,
        stderr: String? = nil,
        willRetry: Bool? = nil
    ) async {
        await dependencies.diagnosticsLogger.log(
            RemoteDiagnosticsRecord(
                level: level,
                category: category,
                hostId: host.id,
                hostName: host.displayName,
                sshTarget: host.sshTarget,
                connectionId: connectionId,
                requestId: requestId,
                method: method,
                threadId: threadId,
                turnId: turnId,
                itemId: itemId,
                message: message,
                payload: payload,
                exitCode: exitCode,
                stderr: stderr,
                willRetry: willRetry
            )
        )
    }
}
