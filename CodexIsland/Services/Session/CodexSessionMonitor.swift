//
//  CodexSessionMonitor.swift
//  CodexIsland
//
//  MainActor wrapper around SessionStore for UI binding.
//  Publishes SessionState arrays for SwiftUI observation.
//

import AppKit
import Combine
import Foundation

@MainActor
class CodexSessionMonitor: ObservableObject {
    enum LocalSendResult: Equatable {
        case sent
        case initializing
        case failed(String)
    }

    private static let localAppServerHost = RemoteHostConfig(
        id: "local-app-server",
        name: "Local App Server",
        sshTarget: "local-app-server",
        defaultCwd: "",
        isEnabled: true
    )

    @Published var instances: [SessionState] = []
    @Published var pendingInstances: [SessionState] = []
    @Published private(set) var localAppServerThreads: [String: RemoteThreadState] = [:]

    private var cancellables = Set<AnyCancellable>()
    private var codexLivenessTask: Task<Void, Never>?
    private let localAppServerMonitor: RemoteSessionMonitor
    private let canSendTerminalInput: @Sendable (SessionState) -> Bool
    private let sendTerminalInput: @Sendable (String, SessionState) async -> Bool
    private var latestStoreSessions: [SessionState] = []
    private var pendingLocalThreadLoads: Set<String> = []
    private var dismissedSyntheticSessionIds: Set<String> = []

    init(
        localAppServerMonitor: RemoteSessionMonitor? = nil,
        canSendTerminalInput: @escaping @Sendable (SessionState) -> Bool = { session in
            NativeTerminalInputSender.shared.canSend(to: session)
        },
        sendTerminalInput: @escaping @Sendable (String, SessionState) async -> Bool = { text, session in
            await NativeTerminalInputSender.shared.send(
                steps: [.text(text), .enter],
                to: session
            )
        }
    ) {
        self.localAppServerMonitor = localAppServerMonitor ?? Self.makeLocalAppServerMonitor()
        self.canSendTerminalInput = canSendTerminalInput
        self.sendTerminalInput = sendTerminalInput

        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)

        self.localAppServerMonitor.$threads
            .receive(on: DispatchQueue.main)
            .sink { [weak self] threads in
                guard let self else { return }
                self.localAppServerThreads = Dictionary(
                    uniqueKeysWithValues: threads.map { ($0.threadId, $0) }
                )
                self.updateFromSessions(self.latestStoreSessions)
            }
            .store(in: &cancellables)

        InterruptWatcherManager.shared.delegate = self
        CodexTranscriptWatcherManager.shared.delegate = self
    }

    // MARK: - Monitoring Lifecycle

    func startMonitoring() {
        localAppServerMonitor.startMonitoring()
        HookSocketServer.shared.start(
            onEvent: { [weak self] event in
                Task { @MainActor in
                    await SessionStore.shared.process(.hookReceived(event))

                    if event.provider == .codex {
                        await self?.prepareAppServerThread(sessionId: event.sessionId)
                    }
                }

                if event.provider == .claude && event.sessionPhase == .processing {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.startWatching(
                            sessionId: event.sessionId,
                            cwd: event.cwd
                        )
                    }
                }

                if event.provider == .claude && event.status == "ended" {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.stopWatching(sessionId: event.sessionId)
                    }
                }

                if event.event == "Stop" {
                    HookSocketServer.shared.cancelPendingPermissions(sessionId: event.sessionId)
                }

                if event.event == "PostToolUse", let toolUseId = event.toolUseId {
                    HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                }
            },
            onPermissionFailure: { sessionId, toolUseId in
                Task {
                    await SessionStore.shared.process(
                        .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            }
        )

        codexLivenessTask?.cancel()
        codexLivenessTask = Task { [weak self] in
            await self?.monitorCodexProcessLiveness()
        }
    }

    func stopMonitoring() {
        HookSocketServer.shared.stop()
        CodexTranscriptWatcherManager.shared.stopAll()
        codexLivenessTask?.cancel()
        codexLivenessTask = nil
    }

    // MARK: - Permission Handling

    func approvePermission(sessionId: String) {
        Task {
            _ = await respond(sessionId: sessionId, action: .allow)
        }
    }

    func denyPermission(sessionId: String, reason: String?) {
        if let reason, !reason.isEmpty {
            Task {
                guard let session = await SessionStore.shared.session(for: sessionId),
                      let permission = session.activePermission else {
                    return
                }

                HookSocketServer.shared.respondToPermission(
                    toolUseId: permission.toolUseId,
                    decision: "deny",
                    reason: reason
                )

                await SessionStore.shared.process(
                    .permissionDenied(sessionId: sessionId, toolUseId: permission.toolUseId, reason: reason)
                )
            }
            return
        }

        Task {
            _ = await respond(sessionId: sessionId, action: .deny)
        }
    }

    func respond(sessionId: String, action: PendingApprovalAction) async -> LocalSendResult {
        guard let session = await sessionForInteraction(sessionId: sessionId),
              let interaction = pendingInteraction(for: session) else {
            return .failed("Approval request is no longer available.")
        }

        switch interaction {
        case .approval(let approval):
            switch approval.transport {
            case .remoteAppServer:
                switch await ensureAppServerThreadResult(for: session) {
                case .ready(let thread):
                    do {
                        try await localAppServerMonitor.respond(thread: thread, action: action)
                        return .sent
                    } catch {
                        return .failed(error.localizedDescription)
                    }
                case .initializing:
                    return .initializing
                case .failed(let error):
                    return .failed(error.localizedDescription)
                }
            case .hookPermission(let toolUseId):
                let decision = action == .allow ? "allow" : "deny"
                HookSocketServer.shared.respondToPermission(toolUseId: toolUseId, decision: decision)
                if action == .allow {
                    await SessionStore.shared.process(
                        .permissionApproved(sessionId: sessionId, toolUseId: toolUseId)
                    )
                } else {
                    await SessionStore.shared.process(
                        .permissionDenied(sessionId: sessionId, toolUseId: toolUseId, reason: nil)
                    )
                }
                return .sent
            case .codexLocal:
                return .failed("Approval request is no longer available.")
            }
        case .userInput:
            return .failed("Approval request is no longer available.")
        }
    }

    func respond(sessionId: String, answers: PendingInteractionAnswerPayload) async -> Bool {
        guard let session = await sessionForInteraction(sessionId: sessionId),
              case .userInput(let interaction)? = pendingInteraction(for: session) else {
            return false
        }

        switch interaction.transport {
        case .remoteAppServer:
            guard let thread = await ensureAppServerThread(for: session) else { return false }
            do {
                try await localAppServerMonitor.respond(thread: thread, interaction: interaction, answers: answers)
                return true
            } catch {
                return false
            }
        case .codexLocal:
            guard let text = inlineReplyText(for: answers) else { return false }
            if localThread(for: session) == nil,
               canFallbackToTerminalInput(for: session) {
                return await sendTerminalInput(text, session)
            }
            guard let thread = await ensureAppServerThread(for: session) else { return false }
            do {
                try await localAppServerMonitor.sendMessage(thread: thread, text: text)
                return true
            } catch {
                return false
            }
        case .hookPermission:
            return false
        }
    }

    func pendingInteraction(for session: SessionState) -> PendingInteraction? {
        guard session.provider == .codex else {
            return session.primaryPendingInteraction
        }
        if let thread = localThread(for: session) {
            return thread.primaryPendingInteraction ?? session.primaryPendingInteraction
        }
        return session.primaryPendingInteraction
    }

    func canSendMessage(to session: SessionState) -> Bool {
        guard session.provider == .codex else {
            return session.isInTmux && session.tty != nil
        }

        if let thread = localThread(for: session) {
            return thread.canSendMessage
        }

        return canFallbackToTerminalInput(for: session)
    }

    func canRespondInline(to session: SessionState, interaction: PendingInteraction) -> Bool {
        guard session.provider == .codex else {
            return NativeTerminalInputSender.shared.canSend(to: session)
        }

        switch interaction.transport {
        case .remoteAppServer:
            return true
        case .codexLocal:
            return localThread(for: session)?.canSendMessage == true || canFallbackToTerminalInput(for: session)
        case .hookPermission:
            return false
        }
    }

    func preferredHistory(for session: SessionState) -> [ChatHistoryItem]? {
        guard session.provider == .codex,
              let thread = localThread(for: session),
              shouldPreferAppServerHistory(thread) else {
            return nil
        }

        return thread.history
    }

    func prefersAppServerHistory(for session: SessionState) -> Bool {
        preferredHistory(for: session) != nil
    }

    func localAppServerThread(for session: SessionState) -> RemoteThreadState? {
        localThread(for: session)
    }

    func prepareAppServerThread(session: SessionState) async {
        guard session.provider == .codex else { return }
        _ = await ensureAppServerThread(for: session)
    }

    func prepareAppServerThread(sessionId: String) async {
        if let session = await SessionStore.shared.session(for: sessionId) {
            await prepareAppServerThread(session: session)
            return
        }
        guard localAppServerThreads[sessionId] != nil else { return }
    }

    private func sessionForInteraction(sessionId: String) async -> SessionState? {
        if let session = await SessionStore.shared.session(for: sessionId) {
            return session
        }
        return instances.first(where: { $0.sessionId == sessionId })
    }

    private func threadForSessionId(_ sessionId: String) -> RemoteThreadState? {
        localAppServerThreads[sessionId]
    }

    private func runtimeInfo(from thread: RemoteThreadState) -> SessionRuntimeInfo {
        SessionRuntimeInfo(
            model: thread.currentModel,
            reasoningEffort: thread.currentReasoningEffort?.rawValue,
            modelProvider: nil,
            tokenUsage: thread.tokenUsage
        )
    }

    private func conversationInfo(from thread: RemoteThreadState) -> ConversationInfo {
        overlayConversationInfo(
            ConversationInfo(
                summary: nil,
                lastMessage: nil,
                lastMessageRole: nil,
                lastToolName: nil,
                firstUserMessage: nil,
                lastUserMessageDate: nil
            ),
            with: thread
        )
    }

    private func syntheticSession(from thread: RemoteThreadState) -> SessionState {
        // Local app-server threads can outlive the SessionStore metadata that
        // originally spawned them. When that happens we synthesize a minimal
        // SessionState so the UI can still list, resume, and message the thread.
        SessionState(
            sessionId: thread.threadId,
            logicalSessionId: thread.logicalSessionId,
            provider: .codex,
            cwd: thread.cwd,
            projectName: URL(fileURLWithPath: thread.cwd).lastPathComponent,
            transcriptPath: nil,
            pid: nil,
            tty: nil,
            terminalName: nil,
            terminalWindowId: nil,
            terminalTabId: nil,
            terminalSurfaceId: nil,
            isInTmux: false,
            phase: thread.phase,
            chatItems: thread.history,
            pendingInteractions: thread.primaryPendingInteraction.map { [$0] } ?? [],
            conversationInfo: conversationInfo(from: thread),
            runtimeInfo: runtimeInfo(from: thread),
            lastActivity: thread.lastActivity,
            createdAt: thread.createdAt
        )
    }

    private func sessionState(for thread: RemoteThreadState) -> SessionState {
        if let metadataSession = localMetadataSession(for: thread, within: latestStoreSessions) {
            return sessionState(for: thread, metadataSession: metadataSession)
        }
        return syntheticSession(from: thread)
    }

    private func sessionState(
        for thread: RemoteThreadState,
        metadataSession: SessionState
    ) -> SessionState {
        // Metadata from SessionStore still owns terminal binding, process ids,
        // transcript paths, and hook-derived state. The app-server thread then
        // overlays fresher chat/runtime/pending information on top.
        var merged = SessionState(
            sessionId: thread.threadId,
            logicalSessionId: thread.logicalSessionId,
            provider: .codex,
            cwd: thread.cwd,
            projectName: metadataSession.projectName,
            transcriptPath: metadataSession.transcriptPath,
            pid: metadataSession.pid,
            tty: metadataSession.tty,
            terminalName: metadataSession.terminalName,
            terminalBundleId: metadataSession.terminalBundleId,
            terminalProcessId: metadataSession.terminalProcessId,
            terminalWindowId: metadataSession.terminalWindowId,
            terminalTabId: metadataSession.terminalTabId,
            terminalSurfaceId: metadataSession.terminalSurfaceId,
            isInTmux: metadataSession.isInTmux,
            focusTarget: metadataSession.focusTarget,
            focusCapability: metadataSession.focusCapability,
            phase: metadataSession.phase,
            chatItems: metadataSession.chatItems,
            toolTracker: metadataSession.toolTracker,
            subagentState: metadataSession.subagentState,
            pendingInteractions: metadataSession.pendingInteractions,
            conversationInfo: metadataSession.conversationInfo,
            runtimeInfo: metadataSession.runtimeInfo,
            needsClearReconciliation: metadataSession.needsClearReconciliation,
            lastActivity: max(metadataSession.lastActivity, thread.lastActivity),
            createdAt: min(metadataSession.createdAt, thread.createdAt)
        )
        merged = overlayLocalAppServerState(merged, with: thread)
        return merged
    }

    private func syntheticLocalSessions(excluding sessions: [SessionState]) -> [SessionState] {
        let existingSessionIds = Set(sessions.map(\.sessionId))
        let matchedStoreSessionIds = Set(localStoreSessionByThreadId(from: sessions).values.map(\.sessionId))
        return localAppServerThreads.values
            .filter { thread in
                !existingSessionIds.contains(thread.threadId) &&
                    !matchedStoreSessionIds.contains(thread.threadId) &&
                    !dismissedSyntheticSessionIds.contains(thread.threadId)
            }
            .sorted { lhs, rhs in
                if lhs.lastActivity != rhs.lastActivity {
                    return lhs.lastActivity > rhs.lastActivity
                }
                return lhs.threadId < rhs.threadId
            }
            .map(sessionState(for:))
    }

    func requireLocalAppServerThread(sessionId: String) async throws -> RemoteThreadState {
        if let session = await SessionStore.shared.session(for: sessionId) {
            guard session.provider == .codex else {
                throw RemoteSessionError.missingThread
            }

            guard let thread = await ensureAppServerThread(for: session) else {
                throw RemoteSessionError.missingThread
            }

            return thread
        }

        if let thread = threadForSessionId(sessionId) {
            return thread
        }

        throw RemoteSessionError.missingThread
    }

    func listLocalModels(sessionId: String, includeHidden: Bool = false) async throws -> [RemoteAppServerModel] {
        _ = try await requireLocalAppServerThread(sessionId: sessionId)
        return try await localAppServerMonitor.listModels(
            hostId: Self.localAppServerHost.id,
            includeHidden: includeHidden
        )
    }

    func listLocalCollaborationModes(sessionId: String) async throws -> [RemoteAppServerCollaborationModeMask] {
        _ = try await requireLocalAppServerThread(sessionId: sessionId)
        return try await localAppServerMonitor.listCollaborationModes(hostId: Self.localAppServerHost.id)
    }

    func availableLocalThreads(excluding sessionId: String? = nil) -> [SessionState] {
        localAppServerMonitor.availableThreads(
            hostId: Self.localAppServerHost.id,
            excluding: sessionId
        ).map(sessionState(for:))
    }

    func startFreshLocalThread(cwd: String) async throws -> SessionState {
        let thread = try await localAppServerMonitor.startFreshThread(
            hostId: Self.localAppServerHost.id,
            defaultCwd: cwd
        )
        dismissedSyntheticSessionIds.remove(thread.threadId)
        updateFromSessions(latestStoreSessions)
        return sessionState(for: thread)
    }

    func openLocalThread(threadId: String) async throws -> SessionState {
        let thread = try await localAppServerMonitor.openThread(
            hostId: Self.localAppServerHost.id,
            threadId: threadId
        )
        dismissedSyntheticSessionIds.remove(thread.threadId)
        updateFromSessions(latestStoreSessions)
        return sessionState(for: thread)
    }

    func setLocalTurnContext(
        sessionId: String,
        turnContext: RemoteThreadTurnContext,
        synchronizeThread: Bool
    ) async throws -> RemoteThreadState {
        let thread = try await requireLocalAppServerThread(sessionId: sessionId)
        return try await localAppServerMonitor.setTurnContext(
            thread: thread,
            turnContext: turnContext,
            synchronizeThread: synchronizeThread
        )
    }

    func sendMessageResult(sessionId: String, text: String) async -> LocalSendResult {
        if let session = await SessionStore.shared.session(for: sessionId) {
            if session.provider == .codex {
                if localThread(for: session) == nil,
                   canFallbackToTerminalInput(for: session) {
                    return await sendTerminalInput(text, session)
                        ? .sent
                        : .failed("Terminal input fallback failed.")
                }

                switch await ensureAppServerThreadResult(for: session) {
                case .ready(let thread):
                    do {
                        try await localAppServerMonitor.sendMessage(thread: thread, text: text)
                        return .sent
                    } catch {
                        return .failed(error.localizedDescription)
                    }
                case .initializing:
                    return .initializing
                case .failed(let error):
                    return .failed(error.localizedDescription)
                }
            }

            return .failed("Session is unavailable for messaging.")
        }

        if let thread = threadForSessionId(sessionId) {
            do {
                try await localAppServerMonitor.sendMessage(thread: thread, text: text)
                return .sent
            } catch {
                return .failed(error.localizedDescription)
            }
        }

        return .failed("Session is unavailable for messaging.")
    }

    func sendMessage(sessionId: String, text: String) async -> Bool {
        if case .sent = await sendMessageResult(sessionId: sessionId, text: text) {
            return true
        }
        return false
    }

    /// Archive (remove) a session from the instances list
    func archiveSession(sessionId: String) {
        if !latestStoreSessions.contains(where: { $0.sessionId == sessionId }),
           threadForSessionId(sessionId) != nil {
            dismissedSyntheticSessionIds.insert(sessionId)
            updateFromSessions(latestStoreSessions)
            return
        }

        Task {
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        }
    }

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        latestStoreSessions = sessions

        let previousSessionIds = Set(instances.map(\.sessionId))
        let mergedSessions = mergedVisibleSessions(from: sessions)
        let currentSessionIds = Set(mergedSessions.map(\.sessionId))
        let removedSessionIds = previousSessionIds.subtracting(currentSessionIds)
        for sessionId in removedSessionIds {
            InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
            CodexTranscriptWatcherManager.shared.stopWatching(sessionId: sessionId)
            pendingLocalThreadLoads.remove(sessionId)
            dismissedSyntheticSessionIds.remove(sessionId)
        }

        refreshTranscriptWatchers(for: sessions)
        let resolvedHistorySessionIds = Set(
            localAppServerThreads.values
                .filter { shouldPreferAppServerHistory($0) }
                .map(\.threadId)
        )
        ChatHistoryManager.shared.syncVisibleSessions(
            mergedSessions,
            resolvedSessionIds: resolvedHistorySessionIds
        )

        instances = mergedSessions
        pendingInstances = mergedSessions.filter { $0.needsAttention }
    }

    // MARK: - History Loading (for UI)

    /// Request history load for a session
    func loadHistory(sessionId: String, cwd: String) {
        Task {
            await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
        }
    }

    private func overlayLocalAppServerState(_ session: SessionState) -> SessionState {
        guard session.provider == .codex,
              let thread = localThread(for: session) else {
            return session
        }
        return overlayLocalAppServerState(session, with: thread)
    }

    private func overlayLocalAppServerState(
        _ session: SessionState,
        with thread: RemoteThreadState
    ) -> SessionState {
        guard session.provider == .codex else {
            return session
        }

        // App-server state wins only for fields it can observe more accurately
        // than SessionStore: live pending interactions, transcript-backed
        // history, phase, and turn-scoped runtime info.
        var merged = session
        if let threadPendingInteraction = thread.primaryPendingInteraction {
            merged.pendingInteractions = [threadPendingInteraction]
        }

        if shouldPreferAppServerHistory(thread) {
            merged.chatItems = thread.history
            merged.conversationInfo = overlayConversationInfo(
                session.conversationInfo,
                with: thread
            )
        }

        if thread.isLoaded || thread.phase.isActive || thread.needsAttention {
            merged.phase = thread.phase
        }
        if let model = thread.currentModel, !model.isEmpty {
            merged.runtimeInfo.model = model
        }
        if let reasoningEffort = thread.currentReasoningEffort?.rawValue, !reasoningEffort.isEmpty {
            merged.runtimeInfo.reasoningEffort = reasoningEffort
        }
        if let tokenUsage = thread.tokenUsage {
            merged.runtimeInfo.tokenUsage = tokenUsage
        }
        return merged
    }

    private func shouldPreferAppServerHistory(_ thread: RemoteThreadState) -> Bool {
        thread.isLoaded || !thread.history.isEmpty
    }

    private func mergedVisibleSessions(from sessions: [SessionState]) -> [SessionState] {
        // The visible list merges three sources:
        // 1) non-Codex sessions from SessionStore unchanged,
        // 2) Codex sessions that can be matched to a local app-server thread,
        // 3) synthetic app-server threads that no longer have SessionStore metadata.
        let localStoreSessions = sessions.filter { $0.provider == .codex }
        let matchedStoreSessions = localStoreSessionByThreadId(from: localStoreSessions)
        let localThreadSessions = localAppServerThreads.values
            .filter { thread in
                matchedStoreSessions[thread.threadId] != nil ||
                    !dismissedSyntheticSessionIds.contains(thread.threadId)
            }
            .sorted { lhs, rhs in
                if lhs.lastActivity != rhs.lastActivity {
                    return lhs.lastActivity > rhs.lastActivity
                }
                return lhs.threadId < rhs.threadId
            }
            .map { thread in
                if let metadataSession = matchedStoreSessions[thread.threadId] {
                    return sessionState(for: thread, metadataSession: metadataSession)
                }
                return syntheticSession(from: thread)
            }

        let matchedSessionIds = Set(matchedStoreSessions.values.map(\.sessionId))
        let fallbackLocalSessions = localStoreSessions
            .filter { !matchedSessionIds.contains($0.sessionId) }
            .map(overlayLocalAppServerState)

        let nonCodexSessions = sessions.filter { $0.provider != .codex }
        return nonCodexSessions + localThreadSessions + fallbackLocalSessions
    }

    private func localStoreSessionByThreadId(from sessions: [SessionState]) -> [String: SessionState] {
        var matches: [String: (session: SessionState, score: Int)] = [:]

        for session in sessions where session.provider == .codex {
            guard let thread = localThread(for: session) else { continue }
            let score = localThreadMatchScore(session: session, thread: thread)
            if let existing = matches[thread.threadId], existing.score >= score {
                continue
            }
            matches[thread.threadId] = (session, score)
        }

        return matches.mapValues(\.session)
    }

    private func inlineReplyText(for answers: PendingInteractionAnswerPayload) -> String? {
        let value = answers.answers.values
            .flatMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard let value else { return nil }
        return value.replacingOccurrences(of: " (Recommended)", with: "")
    }

    private func canFallbackToTerminalInput(for session: SessionState) -> Bool {
        guard session.provider == .codex else { return false }
        guard session.phase == .idle || session.phase == .waitingForInput || session.primaryPendingInteraction != nil else {
            return false
        }
        return canSendTerminalInput(session)
    }

    private func localMetadataSession(
        for thread: RemoteThreadState,
        within sessions: [SessionState]
    ) -> SessionState? {
        localStoreSessionByThreadId(from: sessions)[thread.threadId]
    }

    private func localThread(for session: SessionState) -> RemoteThreadState? {
        guard session.provider == .codex else { return nil }
        if let knownThread = findKnownAppServerThread(
            for: session,
            candidateThreadIDs: appServerCandidateThreadIDs(for: session)
        ) {
            return knownThread
        }

        let normalizedCwd = normalizedCwdIdentity(session.cwd)
        guard !normalizedCwd.isEmpty else { return nil }
        // Cwd-only matching is a last resort for older sessions that predate
        // persisted thread ids. It is intentionally weak and only used when we
        // cannot recover a stronger match from session id or transcript path.
        return localAppServerThreads.values.first {
            normalizedCwdIdentity($0.cwd) == normalizedCwd
        }
    }

    private func localThreadMatchScore(session: SessionState, thread: RemoteThreadState) -> Int {
        if session.sessionId == thread.threadId {
            return 3
        }

        if let transcriptPath = session.transcriptPath,
           localAppServerMonitor.findThread(
               hostId: Self.localAppServerHost.id,
               threadId: nil,
               transcriptPath: transcriptPath
           )?.threadId == thread.threadId {
            return 2
        }

        if normalizedCwdIdentity(session.cwd) == normalizedCwdIdentity(thread.cwd) {
            return 1
        }

        return 0
    }

    private func normalizedCwdIdentity(_ cwd: String) -> String {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.hasPrefix("/") else { return trimmed }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private func refreshTranscriptWatchers(for sessions: [SessionState]) {
        let codexSessions = sessions.filter { $0.provider == .codex }
        let activeCodexSessionIds = Set(codexSessions.map(\.sessionId))

        for session in codexSessions {
            guard let transcriptPath = session.transcriptPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !transcriptPath.isEmpty else {
                CodexTranscriptWatcherManager.shared.stopWatching(sessionId: session.sessionId)
                continue
            }

            if localThread(for: session) != nil {
                CodexTranscriptWatcherManager.shared.stopWatching(sessionId: session.sessionId)
                continue
            }

            CodexTranscriptWatcherManager.shared.startWatching(
                sessionId: session.sessionId,
                transcriptPath: transcriptPath
            )
        }

        for watcherSessionId in activeCodexWatcherSessionIds().subtracting(activeCodexSessionIds) {
            CodexTranscriptWatcherManager.shared.stopWatching(sessionId: watcherSessionId)
        }
    }

    private func activeCodexWatcherSessionIds() -> Set<String> {
        Set(
            latestStoreSessions
                .filter { $0.provider == .codex && $0.transcriptPath != nil }
                .map(\.sessionId)
        )
    }

    private func overlayConversationInfo(
        _ base: ConversationInfo,
        with thread: RemoteThreadState
    ) -> ConversationInfo {
        let firstUserMessage = base.firstUserMessage ?? thread.history.first(where: { item in
            if case .user = item.type {
                return true
            }
            return false
        }).flatMap { item in
            if case .user(let text) = item.type {
                return text
            }
            return nil
        }

        let summaryFallback: String?
        if let name = thread.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            summaryFallback = name
        } else {
            let preview = thread.preview.trimmingCharacters(in: .whitespacesAndNewlines)
            summaryFallback = preview.isEmpty ? nil : preview
        }

        return ConversationInfo(
            summary: base.summary ?? summaryFallback,
            lastMessage: thread.lastMessage ?? base.lastMessage,
            lastMessageRole: thread.lastMessageRole ?? base.lastMessageRole,
            lastToolName: thread.lastToolName ?? base.lastToolName,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: thread.lastUserMessageDate ?? base.lastUserMessageDate
        )
    }

    private enum AppServerThreadResolution {
        case ready(RemoteThreadState)
        case initializing
        case failed(RemoteSessionError)
    }

    private func ensureAppServerThread(for session: SessionState) async -> RemoteThreadState? {
        if case .ready(let thread) = await ensureAppServerThreadResult(for: session) {
            return thread
        }
        return nil
    }

    private func ensureAppServerThreadResult(for session: SessionState) async -> AppServerThreadResolution {
        guard session.provider == .codex else {
            return .failed(.transport("Session is unavailable for messaging."))
        }
        let candidateThreadIDs = appServerCandidateThreadIDs(for: session)

        // A local session may be addressable by the persisted session id, an id
        // embedded in the transcript filename, or a thread discovered after a
        // refresh/open cycle. We try those progressively before declaring the
        // app-server thread missing.
        if let thread = findKnownAppServerThread(
            for: session,
            candidateThreadIDs: candidateThreadIDs
        ) {
            return .ready(thread)
        }
        if pendingLocalThreadLoads.contains(session.sessionId) {
            return .initializing
        }

        pendingLocalThreadLoads.insert(session.sessionId)
        defer { pendingLocalThreadLoads.remove(session.sessionId) }
        var lastError: RemoteSessionError?

        for attempt in 0 ..< 4 {
            if let thread = findKnownAppServerThread(
                for: session,
                candidateThreadIDs: candidateThreadIDs
            ) {
                return .ready(thread)
            }

            do {
                try await localAppServerMonitor.refreshHostNow(id: Self.localAppServerHost.id)
            } catch {
                lastError = presentableLocalThreadLoadError(error)
                if attempt == 3 {
                    break
                }
            }

            if let thread = findKnownAppServerThread(
                for: session,
                candidateThreadIDs: candidateThreadIDs
            ) {
                return .ready(thread)
            }

            for threadID in candidateThreadIDs {
                do {
                    let openedThread = try await localAppServerMonitor.openThread(
                        hostId: Self.localAppServerHost.id,
                        threadId: threadID
                    )
                    return .ready(openedThread)
                } catch {
                    lastError = presentableLocalThreadLoadError(error)
                }
            }

            if attempt < 3 {
                try? await Task.sleep(for: .milliseconds(150))
            }
        }

        if let lastError {
            return .failed(lastError)
        }

        return .initializing
    }

    private func presentableLocalThreadLoadError(_ error: Error) -> RemoteSessionError {
        if let remoteError = error as? RemoteSessionError {
            return remoteError
        }
        return .transport(error.localizedDescription)
    }

    private func findKnownAppServerThread(
        for session: SessionState,
        candidateThreadIDs: [String]
    ) -> RemoteThreadState? {
        for threadID in candidateThreadIDs {
            if let thread = localAppServerMonitor.findThread(
                hostId: Self.localAppServerHost.id,
                threadId: threadID,
                transcriptPath: session.transcriptPath
            ) {
                return thread
            }
        }

        return localAppServerMonitor.findThread(
            hostId: Self.localAppServerHost.id,
            threadId: nil,
            transcriptPath: session.transcriptPath
        )
    }

    private func appServerCandidateThreadIDs(for session: SessionState) -> [String] {
        var candidates: [String] = []

        func appendCandidate(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !candidates.contains(trimmed) else { return }
            candidates.append(trimmed)
        }

        appendCandidate(session.sessionId)

        if let transcriptPath = session.transcriptPath {
            // Transcript filenames often carry the canonical app-server thread
            // id as a trailing UUID-like segment. Preserve it as a recovery key
            // so reopened sessions can reconnect after metadata drift.
            let filename = URL(fileURLWithPath: transcriptPath).deletingPathExtension().lastPathComponent
            if let match = filename.range(
                of: #"[0-9a-f]{8,}-[0-9a-f-]{20,}$"#,
                options: .regularExpression
            ) {
                appendCandidate(String(filename[match]))
            }
        }

        return candidates
    }

    private static func makeLocalAppServerMonitor() -> RemoteSessionMonitor {
        let host = localAppServerHost
        return RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            connectionFactory: { host, emit in
                RemoteAppServerConnection(
                    host: host,
                    emit: emit,
                    dependencies: .local
                )
            }
        )
    }

    func handleCodexProcessExit(for session: SessionState) async {
        await ChatHistoryManager.shared.syncFromFile(sessionId: session.sessionId, cwd: session.cwd)

        if let thread = findKnownAppServerThread(
            for: session,
            candidateThreadIDs: appServerCandidateThreadIDs(for: session)
        ) {
            dismissedSyntheticSessionIds.insert(thread.threadId)
        }

        await SessionStore.shared.process(.codexProcessExited(sessionId: session.sessionId))
    }

    private func monitorCodexProcessLiveness() async {
        while !Task.isCancelled {
            let sessions = await SessionStore.shared.allSessions()
            for session in sessions where session.provider == .codex && session.pid != nil {
                guard let pid = session.pid else { continue }
                if !processExists(pid: pid) {
                    await handleCodexProcessExit(for: session)
                }
            }

            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
        }
    }

    private nonisolated func processExists(pid: Int) -> Bool {
        if kill(pid_t(pid), 0) == 0 {
            return true
        }
        return errno != ESRCH
    }
}

// MARK: - Interrupt Watcher Delegate

extension CodexSessionMonitor: JSONLInterruptWatcherDelegate {
    nonisolated func didDetectInterrupt(sessionId: String) {
        Task {
            await SessionStore.shared.process(.interruptDetected(sessionId: sessionId))
        }

        Task { @MainActor in
            InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
        }
    }
}

extension CodexSessionMonitor: CodexTranscriptWatcherDelegate {
    nonisolated func didUpdateCodexTranscript(sessionId: String) {
        Task { @MainActor in
            guard let session = await SessionStore.shared.session(for: sessionId) else { return }
            guard localThread(for: session) == nil else { return }
            let result = await SessionTranscriptParser.shared.parseIncremental(session: session)

            if result.clearDetected {
                await SessionStore.shared.process(.clearDetected(sessionId: sessionId))
            }

            let payload = FileUpdatePayload(
                sessionId: sessionId,
                cwd: session.cwd,
                messages: result.newMessages,
                isIncremental: !result.clearDetected,
                completedToolIds: result.completedToolIds,
                toolResults: result.toolResults,
                structuredResults: result.structuredResults,
                pendingInteractions: result.pendingInteractions,
                transcriptPhase: result.transcriptPhase
            )
            await SessionStore.shared.process(.fileUpdated(payload))
            await ChatHistoryManager.shared.syncFromFile(sessionId: sessionId, cwd: session.cwd)
        }
    }
}
