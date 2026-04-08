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

    static let localAppServerHost = RemoteHostConfig(
        id: "local-app-server",
        name: "Local App Server",
        sshTarget: "local-app-server",
        defaultCwd: "",
        isEnabled: true
    )

    @Published var instances: [SessionState] = []
    @Published var pendingInstances: [SessionState] = []
    @Published private(set) var localAppServerThreads: [String: RemoteThreadState] = [:]

    var cancellables = Set<AnyCancellable>()
    var codexLivenessTask: Task<Void, Never>?
    let localAppServerMonitor: RemoteSessionMonitor
    let canSendTerminalInput: @Sendable (SessionState) -> Bool
    let sendTerminalInput: @Sendable (String, SessionState) async -> Bool
    let processExistsHandler: @Sendable (Int) -> Bool
    let stopExitCheckDelay: Duration
    var latestStoreSessions: [SessionState] = []
    var pendingLocalThreadLoads: Set<String> = []
    var dismissedSyntheticSessionIds: Set<String> = []

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
        },
        processExistsHandler: @escaping @Sendable (Int) -> Bool = { pid in
            if kill(pid_t(pid), 0) == 0 {
                return true
            }
            return errno != ESRCH
        },
        stopExitCheckDelay: Duration = .milliseconds(250)
    ) {
        self.localAppServerMonitor = localAppServerMonitor ?? Self.makeLocalAppServerMonitor()
        self.canSendTerminalInput = canSendTerminalInput
        self.sendTerminalInput = sendTerminalInput
        self.processExistsHandler = processExistsHandler
        self.stopExitCheckDelay = stopExitCheckDelay

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
                    Task { @MainActor [weak self] in
                        await self?.schedulePostStopExitCheck(for: event)
                    }
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
        let hasBackedStoreSession = latestStoreSessions.contains { $0.sessionId == sessionId }
        let hasVisibleSyntheticSession = instances.contains { $0.sessionId == sessionId }
        if !hasBackedStoreSession, hasVisibleSyntheticSession {
            dismissedSyntheticSessionIds.insert(sessionId)
            updateFromSessions(latestStoreSessions)
            return
        }

        Task {
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        }
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

    enum AppServerThreadResolution {
        case ready(RemoteThreadState)
        case initializing
        case failed(RemoteSessionError)
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
