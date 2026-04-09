//
//  CodexSessionMonitor+LocalAppServer.swift
//  CodexIsland
//
//  Local app-server thread discovery, overlay, and bridge helpers.
//

import Foundation

extension CodexSessionMonitor {
    func sessionForInteraction(sessionId: String) async -> SessionState? {
        if let session = await SessionStore.shared.session(for: sessionId) {
            return session
        }
        return instances.first(where: { $0.sessionId == sessionId })
    }

    func threadForSessionId(_ sessionId: String) -> RemoteThreadState? {
        localAppServerThreads[sessionId]
    }

    func runtimeInfo(from thread: RemoteThreadState) -> SessionRuntimeInfo {
        SessionRuntimeInfo(
            model: thread.currentModel,
            reasoningEffort: thread.currentReasoningEffort?.rawValue,
            modelProvider: nil,
            tokenUsage: thread.tokenUsage
        )
    }

    func conversationInfo(from thread: RemoteThreadState) -> ConversationInfo {
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

    func syntheticSession(from thread: RemoteThreadState) -> SessionState {
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

    func sessionState(for thread: RemoteThreadState) -> SessionState {
        if let metadataSession = localMetadataSession(for: thread, within: latestStoreSessions) {
            return sessionState(for: thread, metadataSession: metadataSession)
        }
        return syntheticSession(from: thread)
    }

    func sessionState(for thread: RemoteThreadState, metadataSession: SessionState) -> SessionState {
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

    func syntheticLocalSessions(excluding sessions: [SessionState]) -> [SessionState] {
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
        return try await localAppServerMonitor.listModels(hostId: Self.localAppServerHost.id, includeHidden: includeHidden)
    }

    func listLocalCollaborationModes(sessionId: String) async throws -> [RemoteAppServerCollaborationModeMask] {
        _ = try await requireLocalAppServerThread(sessionId: sessionId)
        return try await localAppServerMonitor.listCollaborationModes(hostId: Self.localAppServerHost.id)
    }

    func availableLocalThreads(excluding sessionId: String? = nil) -> [SessionState] {
        localAppServerMonitor.availableThreads(hostId: Self.localAppServerHost.id, excluding: sessionId).map(sessionState(for:))
    }

    func startFreshLocalThread(cwd: String) async throws -> SessionState {
        let thread = try await localAppServerMonitor.startFreshThread(hostId: Self.localAppServerHost.id, defaultCwd: cwd)
        dismissedSyntheticSessionIds.remove(thread.threadId)
        updateFromSessions(latestStoreSessions)
        return sessionState(for: thread)
    }

    func openLocalThread(threadId: String) async throws -> SessionState {
        let thread = try await localAppServerMonitor.openThread(hostId: Self.localAppServerHost.id, threadId: threadId)
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

    func localMetadataSession(for thread: RemoteThreadState, within sessions: [SessionState]) -> SessionState? {
        localStoreSessionByThreadId(from: sessions)[thread.threadId]
    }

    func localThread(for session: SessionState) -> RemoteThreadState? {
        guard session.provider == .codex else { return nil }
        if let knownThread = findKnownAppServerThread(for: session, candidateThreadIDs: appServerCandidateThreadIDs(for: session)) {
            return knownThread
        }

        let normalizedCwd = normalizedCwdIdentity(session.cwd)
        guard !normalizedCwd.isEmpty else { return nil }
        return localAppServerThreads.values.first {
            normalizedCwdIdentity($0.cwd) == normalizedCwd
        }
    }

    func localThreadMatchScore(session: SessionState, thread: RemoteThreadState) -> Int {
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

    func normalizedCwdIdentity(_ cwd: String) -> String {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.hasPrefix("/") else { return trimmed }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    func overlayConversationInfo(_ base: ConversationInfo, with thread: RemoteThreadState) -> ConversationInfo {
        let firstUserMessage = base.firstUserMessage ?? thread.history.first(where: { item in
            if case .user = item.type { return true }
            return false
        }).flatMap { item in
            if case .user(let text) = item.type { return text }
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

    func ensureAppServerThread(for session: SessionState) async -> RemoteThreadState? {
        if case .ready(let thread) = await ensureAppServerThreadResult(for: session) {
            return thread
        }
        return nil
    }

    func ensureAppServerThreadResult(for session: SessionState) async -> AppServerThreadResolution {
        guard session.provider == .codex else {
            return .failed(.transport("Session is unavailable for messaging."))
        }

        let candidateThreadIDs = appServerCandidateThreadIDs(for: session)
        if let thread = findKnownAppServerThread(for: session, candidateThreadIDs: candidateThreadIDs) {
            return .ready(thread)
        }
        if pendingLocalThreadLoads.contains(session.sessionId) {
            return .initializing
        }

        pendingLocalThreadLoads.insert(session.sessionId)
        defer { pendingLocalThreadLoads.remove(session.sessionId) }
        var lastError: RemoteSessionError?

        for attempt in 0 ..< 4 {
            if let thread = findKnownAppServerThread(for: session, candidateThreadIDs: candidateThreadIDs) {
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

            if let thread = findKnownAppServerThread(for: session, candidateThreadIDs: candidateThreadIDs) {
                return .ready(thread)
            }

            for threadID in candidateThreadIDs {
                do {
                    let openedThread = try await localAppServerMonitor.openThread(hostId: Self.localAppServerHost.id, threadId: threadID)
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

    func presentableLocalThreadLoadError(_ error: Error) -> RemoteSessionError {
        if let remoteError = error as? RemoteSessionError {
            return remoteError
        }
        return .transport(error.localizedDescription)
    }

    func findKnownAppServerThread(
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

    func appServerCandidateThreadIDs(for session: SessionState) -> [String] {
        var candidates: [String] = []

        func appendCandidate(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !candidates.contains(trimmed) else { return }
            candidates.append(trimmed)
        }

        appendCandidate(session.sessionId)

        if let transcriptPath = session.transcriptPath {
            let filename = URL(fileURLWithPath: transcriptPath).deletingPathExtension().lastPathComponent
            if let match = filename.range(of: #"[0-9a-f]{8,}-[0-9a-f-]{20,}$"#, options: .regularExpression) {
                appendCandidate(String(filename[match]))
            }
        }

        return candidates
    }

    static func makeLocalAppServerMonitor() -> any RemoteSessionControlling {
        SharedEngineRemoteSessionBackend(localHost: localAppServerHost)
    }
}
