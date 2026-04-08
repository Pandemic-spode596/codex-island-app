//
//  CodexSessionMonitor+StateSync.swift
//  CodexIsland
//
//  SwiftUI-visible state merging, watcher coordination, and liveness polling.
//

import Foundation

extension CodexSessionMonitor {
    func updateFromSessions(_ sessions: [SessionState]) {
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
        ChatHistoryManager.shared.syncVisibleSessions(mergedSessions, resolvedSessionIds: resolvedHistorySessionIds)

        instances = mergedSessions
        pendingInstances = mergedSessions.filter { $0.needsAttention }
    }

    func loadHistory(sessionId: String, cwd: String) {
        Task {
            await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
        }
    }

    func overlayLocalAppServerState(_ session: SessionState) -> SessionState {
        guard session.provider == .codex, let thread = localThread(for: session) else {
            return session
        }
        return overlayLocalAppServerState(session, with: thread)
    }

    func overlayLocalAppServerState(_ session: SessionState, with thread: RemoteThreadState) -> SessionState {
        guard session.provider == .codex else { return session }

        var merged = session
        if let threadPendingInteraction = thread.primaryPendingInteraction {
            merged.pendingInteractions = [threadPendingInteraction]
        }

        if shouldPreferAppServerHistory(thread) {
            merged.chatItems = thread.history
            merged.conversationInfo = overlayConversationInfo(session.conversationInfo, with: thread)
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

    func shouldPreferAppServerHistory(_ thread: RemoteThreadState) -> Bool {
        thread.isLoaded || !thread.history.isEmpty
    }

    func mergedVisibleSessions(from sessions: [SessionState]) -> [SessionState] {
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

    func localStoreSessionByThreadId(from sessions: [SessionState]) -> [String: SessionState] {
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

    func refreshTranscriptWatchers(for sessions: [SessionState]) {
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

    func activeCodexWatcherSessionIds() -> Set<String> {
        Set(
            latestStoreSessions
                .filter { $0.provider == .codex && $0.transcriptPath != nil }
                .map(\.sessionId)
        )
    }

    func handleCodexProcessExit(for session: SessionState) async {
        await ChatHistoryManager.shared.syncFromFile(sessionId: session.sessionId, cwd: session.cwd)

        if let thread = findKnownAppServerThread(for: session, candidateThreadIDs: appServerCandidateThreadIDs(for: session)) {
            dismissedSyntheticSessionIds.insert(thread.threadId)
        }

        await SessionStore.shared.process(.codexProcessExited(sessionId: session.sessionId))
    }

    func schedulePostStopExitCheck(for event: HookEvent) async {
        guard event.provider == .codex,
              event.event == "Stop",
              let pid = event.pid else {
            return
        }

        do {
            try await Task.sleep(for: stopExitCheckDelay)
        } catch {
            return
        }

        guard let session = await SessionStore.shared.session(for: event.sessionId),
              session.provider == .codex,
              session.pid == pid,
              !processExists(pid: pid) else {
            return
        }

        await handleCodexProcessExit(for: session)
    }

    func monitorCodexProcessLiveness() async {
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

    nonisolated func processExists(pid: Int) -> Bool {
        processExistsHandler(pid)
    }
}
