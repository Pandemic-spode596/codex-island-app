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
    private var latestStoreSessions: [SessionState] = []
    private var pendingLocalThreadLoads: Set<String> = []

    init(localAppServerMonitor: RemoteSessionMonitor? = nil) {
        self.localAppServerMonitor = localAppServerMonitor ?? Self.makeLocalAppServerMonitor()

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

                if event.provider == .codex,
                   let transcriptPath = event.transcriptPath,
                   !transcriptPath.isEmpty {
                    Task { @MainActor in
                        CodexTranscriptWatcherManager.shared.startWatching(
                            sessionId: event.sessionId,
                            transcriptPath: transcriptPath
                        )
                    }
                }

                if event.provider == .codex && event.status == "ended" {
                    Task { @MainActor in
                        CodexTranscriptWatcherManager.shared.stopWatching(sessionId: event.sessionId)
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
        respond(sessionId: sessionId, action: .allow)
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

        respond(sessionId: sessionId, action: .deny)
    }

    func respond(sessionId: String, action: PendingApprovalAction) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let interaction = pendingInteraction(for: session) else {
                return
            }

            switch interaction {
            case .approval(let approval):
                switch approval.transport {
                case .remoteAppServer:
                    guard let thread = await ensureAppServerThread(for: session) else { return }
                    try? await localAppServerMonitor.respond(thread: thread, action: action)
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
                case .codexLocal:
                    guard let steps = localApprovalSteps(for: approval, action: action),
                          await NativeTerminalInputSender.shared.send(steps: steps, to: session) else {
                        return
                    }
                    await refreshSessionAfterInteraction(session)
                }
            case .userInput:
                break
            }
        }
    }

    func respond(sessionId: String, answers: PendingInteractionAnswerPayload) async -> Bool {
        guard let session = await SessionStore.shared.session(for: sessionId),
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
            guard interaction.supportsInlineResponse,
                  let steps = localUserInputSteps(for: interaction, answers: answers),
                  await NativeTerminalInputSender.shared.send(steps: steps, to: session) else {
                return false
            }

            let isTerminalAnswer = answers.answers.keys.count == interaction.questions.count
            if isTerminalAnswer {
                await refreshSessionAfterInteraction(session)
            }
            return true
        case .hookPermission:
            return false
        }
    }

    func pendingInteraction(for session: SessionState) -> PendingInteraction? {
        guard session.provider == .codex else {
            return session.primaryPendingInteraction
        }
        return localAppServerThreads[session.sessionId]?.primaryPendingInteraction ?? session.primaryPendingInteraction
    }

    func canSendMessage(to session: SessionState) -> Bool {
        guard session.provider == .codex else {
            return session.isInTmux && session.tty != nil
        }

        if let thread = localAppServerThreads[session.sessionId] {
            return thread.canSendMessage
        }

        return session.primaryPendingInteraction == nil
    }

    func canRespondInline(to session: SessionState, interaction: PendingInteraction) -> Bool {
        guard session.provider == .codex else {
            return NativeTerminalInputSender.shared.canSend(to: session)
        }

        switch interaction.transport {
        case .remoteAppServer:
            return true
        case .codexLocal:
            return NativeTerminalInputSender.shared.canSend(to: session)
        case .hookPermission:
            return false
        }
    }

    func prepareAppServerThread(session: SessionState) async {
        guard session.provider == .codex else { return }
        _ = await ensureAppServerThread(for: session)
    }

    func prepareAppServerThread(sessionId: String) async {
        guard let session = await SessionStore.shared.session(for: sessionId) else { return }
        await prepareAppServerThread(session: session)
    }

    func requireLocalAppServerThread(sessionId: String) async throws -> RemoteThreadState {
        guard let session = await SessionStore.shared.session(for: sessionId),
              session.provider == .codex else {
            throw RemoteSessionError.missingThread
        }

        guard let thread = await ensureAppServerThread(for: session) else {
            throw RemoteSessionError.missingThread
        }

        return thread
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

    func sendMessage(sessionId: String, text: String) async -> Bool {
        guard let session = await SessionStore.shared.session(for: sessionId) else {
            return false
        }

        if session.provider == .codex,
           let thread = await ensureAppServerThread(for: session) {
            do {
                try await localAppServerMonitor.sendMessage(thread: thread, text: text)
                return true
            } catch {
                // Fall through to terminal injection fallback.
            }
        }

        return await sendToTerminalFallback(text: text, session: session)
    }

    /// Archive (remove) a session from the instances list
    func archiveSession(sessionId: String) {
        Task {
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        }
    }

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        latestStoreSessions = sessions

        let previousSessionIds = Set(instances.map(\.sessionId))
        let mergedSessions = sessions.map(overlayLocalAppServerState)
        let currentSessionIds = Set(mergedSessions.map(\.sessionId))
        let removedSessionIds = previousSessionIds.subtracting(currentSessionIds)
        for sessionId in removedSessionIds {
            InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
            CodexTranscriptWatcherManager.shared.stopWatching(sessionId: sessionId)
            pendingLocalThreadLoads.remove(sessionId)
        }

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

    private func refreshSessionAfterInteraction(_ session: SessionState) async {
        try? await Task.sleep(for: .milliseconds(250))
        await SessionStore.shared.process(.loadHistory(sessionId: session.sessionId, cwd: session.cwd))
    }

    private func overlayLocalAppServerState(_ session: SessionState) -> SessionState {
        guard session.provider == .codex,
              let thread = localAppServerThreads[session.sessionId] else {
            return session
        }

        var merged = session
        merged.pendingInteractions = thread.primaryPendingInteraction.map { [$0] } ?? []

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

    private func ensureAppServerThread(for session: SessionState) async -> RemoteThreadState? {
        guard session.provider == .codex else { return nil }
        let candidateThreadIDs = appServerCandidateThreadIDs(for: session)

        if let thread = findKnownAppServerThread(
            for: session,
            candidateThreadIDs: candidateThreadIDs
        ) {
            return thread
        }
        if pendingLocalThreadLoads.contains(session.sessionId) {
            return nil
        }

        pendingLocalThreadLoads.insert(session.sessionId)
        defer { pendingLocalThreadLoads.remove(session.sessionId) }

        for attempt in 0..<4 {
            if let thread = findKnownAppServerThread(
                for: session,
                candidateThreadIDs: candidateThreadIDs
            ) {
                return thread
            }

            do {
                try await localAppServerMonitor.refreshHostNow(id: Self.localAppServerHost.id)
            } catch {
                if attempt == 3 {
                    break
                }
            }

            if let thread = findKnownAppServerThread(
                for: session,
                candidateThreadIDs: candidateThreadIDs
            ) {
                return thread
            }

            for threadID in candidateThreadIDs {
                if let openedThread = try? await localAppServerMonitor.openThread(
                    hostId: Self.localAppServerHost.id,
                    threadId: threadID
                ) {
                    return openedThread
                }
            }

            if attempt < 3 {
                try? await Task.sleep(for: .milliseconds(150))
            }
        }

        return nil
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

    private func sendToTerminalFallback(text: String, session: SessionState) async -> Bool {
        guard session.isInTmux,
              let tty = session.tty,
              let target = await TmuxController.shared.findTmuxTarget(forTTY: tty) else {
            return false
        }

        return await ToolApprovalHandler.shared.sendMessage(text, to: target)
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

    private func monitorCodexProcessLiveness() async {
        while !Task.isCancelled {
            let sessions = await SessionStore.shared.allSessions()
            for session in sessions where session.provider == .codex && (session.phase.isActive || session.needsAttention) {
                guard let pid = session.pid else { continue }
                if !processExists(pid: pid) {
                    await ChatHistoryManager.shared.syncFromFile(sessionId: session.sessionId, cwd: session.cwd)
                    await SessionStore.shared.process(.codexProcessExited(sessionId: session.sessionId))
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

    private func localApprovalSteps(
        for interaction: PendingApprovalInteraction,
        action: PendingApprovalAction
    ) -> [TerminalInputStep]? {
        switch interaction.kind {
        case .permissions:
            switch action {
            case .allow:
                return [.key("y")]
            case .allowForSession:
                return [.key("a")]
            case .deny:
                return [.key("n")]
            case .cancel:
                return nil
            }
        case .commandExecution, .fileChange, .generic:
            switch action {
            case .allow:
                return [.key("y")]
            case .allowForSession:
                return interaction.availableActions.contains(.allowForSession) ? [.key("a")] : nil
            case .deny:
                if interaction.availableActions.contains(.deny) {
                    return [.key("d")]
                }
                return nil
            case .cancel:
                if interaction.availableActions.contains(.cancel) {
                    return [.key("n")]
                }
                return nil
            }
        }
    }

    private func localUserInputSteps(
        for interaction: PendingUserInputInteraction,
        answers: PendingInteractionAnswerPayload
    ) -> [TerminalInputStep]? {
        var steps: [TerminalInputStep] = []

        for question in interaction.questions {
            guard let questionAnswers = answers.answers[question.id] else { continue }

            if question.isChoiceQuestion {
                guard let selectedLabel = questionAnswers.first,
                      let optionIndex = question.options.firstIndex(where: { $0.label == selectedLabel }) else {
                    return nil
                }
                steps.append(.key(String(optionIndex + 1)))
                continue
            }

            let text = questionAnswers.first ?? ""
            if !text.isEmpty {
                steps.append(.text(text))
            }
            steps.append(.enter)
        }

        return steps.isEmpty ? nil : steps
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
