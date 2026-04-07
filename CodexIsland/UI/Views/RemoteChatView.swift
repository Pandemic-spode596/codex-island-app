//
//  RemoteChatView.swift
//  CodexIsland
//
//  Chat surface for app-server managed remote threads.
//

import SwiftUI

enum RemoteChatSubmitAction: Equatable {
    case send(String)
    case command(RemoteSlashCommand, args: String?)
    case rejectSlashCommand(String)
}

// Remote slash commands mirror the local composer UX, but every action goes
// through RemoteSessionMonitor so the selected host and visible thread stay in
// sync with the app-server's canonical state.
enum RemoteSlashCommand: String, CaseIterable, Identifiable {
    case plan = "/plan"
    case model = "/model"
    case permissions = "/permissions"
    case new = "/new"
    case resume = "/resume"

    var id: String { rawValue }

    var title: String { rawValue }

    var bareName: String {
        String(rawValue.dropFirst())
    }

    var description: String {
        switch self {
        case .plan:
            return "切到 Plan mode"
        case .model:
            return "选择模型与 reasoning"
        case .permissions:
            return "选择权限 preset"
        case .new:
            return "新建空白远端会话"
        case .resume:
            return "恢复保存的远端线程"
        }
    }

    var supportsInlineArgs: Bool {
        self == .plan
    }

    var requiresStartableThread: Bool {
        switch self {
        case .plan, .model, .permissions:
            return true
        case .new, .resume:
            return false
        }
    }

    static func matches(for text: String) -> [RemoteSlashCommand] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return [] }
        let token = String(trimmed.dropFirst()).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        if token.isEmpty {
            return allCases
        }
        return allCases.filter { $0.bareName.hasPrefix(token.lowercased()) }
    }

    static func submitAction(for text: String) -> RemoteChatSubmitAction? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") {
            let commandBody = String(trimmed.dropFirst())
            let parts = commandBody.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard let first = parts.first else { return nil }
            let name = String(first)
            let args = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : nil
            if let command = allCases.first(where: { $0.bareName == name }) {
                return .command(command, args: args?.isEmpty == true ? nil : args)
            }
            return .rejectSlashCommand("Unsupported remote command: \(trimmed)")
        }
        return .send(trimmed)
    }
}

enum RemoteSlashPanel: Equatable {
    case model
    case permissions
    case resume
}

struct RemoteApprovalPreset: Identifiable, Equatable {
    let id: String
    let label: String
    let description: String
    let approvalPolicy: RemoteAppServerApprovalPolicy
    let sandboxPolicy: RemoteAppServerSandboxPolicy

    static let builtIn: [RemoteApprovalPreset] = [
        RemoteApprovalPreset(
            id: "read-only",
            label: "Read Only",
            description: "Codex can read files in the current workspace. Approval is required to edit files or access the internet.",
            approvalPolicy: .onRequest,
            sandboxPolicy: .readOnly()
        ),
        RemoteApprovalPreset(
            id: "auto",
            label: "Default",
            description: "Codex can read and edit files in the current workspace, and run commands. Approval is required to access the internet or edit other files.",
            approvalPolicy: .onRequest,
            sandboxPolicy: .workspaceWrite()
        ),
        RemoteApprovalPreset(
            id: "full-access",
            label: "Full Access",
            description: "Codex can edit files outside this workspace and access the internet without asking for approval.",
            approvalPolicy: .never,
            sandboxPolicy: .dangerFullAccess
        )
    ]
}

struct RemoteChatView: View {
    let initialThread: RemoteThreadState
    @ObservedObject var remoteSessionMonitor: RemoteSessionMonitor
    @ObservedObject var viewModel: NotchViewModel

    @State private var thread: RemoteThreadState
    @State private var inputText: String = ""
    @State private var shouldScrollToBottom: Bool = false
    @State private var isAutoscrollPaused = false
    @State private var newMessageCount = 0
    @State private var previousHistoryCount = 0
    @State private var activeSlashPanel: RemoteSlashPanel?
    @State private var slashFeedbackMessage: String?
    @State private var isSlashPanelLoading = false
    @State private var isExecutingSlashAction = false
    @State private var isOpeningThread = false
    @State private var availableModels: [RemoteAppServerModel] = []
    @State private var selectedModelForEffort: RemoteAppServerModel?
    @State private var resumeCandidates: [RemoteThreadState] = []
    @FocusState private var isInputFocused: Bool
    @State private var isHeaderHovered = false

    init(
        initialThread: RemoteThreadState,
        remoteSessionMonitor: RemoteSessionMonitor,
        viewModel: NotchViewModel
    ) {
        self.initialThread = initialThread
        self.remoteSessionMonitor = remoteSessionMonitor
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._thread = State(initialValue: initialThread)
    }

    private var history: [ChatHistoryItem] {
        thread.history
    }

    private var pendingInteraction: PendingInteraction? {
        thread.primaryPendingInteraction
    }

    private var matchingSlashCommands: [RemoteSlashCommand] {
        guard activeSlashPanel == nil else { return [] }
        return RemoteSlashCommand.matches(for: inputText)
    }

    private var isPlanModeActive: Bool {
        thread.turnContext.collaborationMode?.mode == .plan
    }

    private var shouldLoadThreadDetails: Bool {
        thread.needsHydration
    }

    var body: some View {
        VStack(spacing: 0) {
            RemoteChatHeaderView(
                thread: thread,
                isPlanModeActive: isPlanModeActive,
                isHeaderHovered: $isHeaderHovered,
                onExit: viewModel.exitChat,
                onInterrupt: interrupt
            )

            if isOpeningThread {
                RemoteChatLoadingStateView()
            } else if history.isEmpty {
                RemoteChatEmptyStateView()
            } else {
                RemoteChatMessageListView(
                    history: history,
                    logicalSessionId: thread.logicalSessionId,
                    shouldScrollToBottom: $shouldScrollToBottom,
                    isAutoscrollPaused: isAutoscrollPaused,
                    newMessageCount: newMessageCount,
                    onResumeAutoscroll: resumeAutoscroll
                )
            }

            if let pendingInteraction {
                PendingInteractionBar(
                    interaction: pendingInteraction,
                    canRespondInline: !pendingInteraction.transport.isLocalCodex,
                    canOpenTerminal: false,
                    onApprovalAction: { action in
                        respondToApproval(action)
                    },
                    onSubmitAnswers: { answers in
                        await respondToQuestions(answers)
                    },
                    onOpenTerminal: {}
                )
                .id(pendingInteraction.id)
            } else {
                RemoteChatComposerView(
                    thread: thread,
                    isPlanModeActive: isPlanModeActive,
                    inputText: $inputText,
                    isInputFocused: $isInputFocused,
                    activeSlashPanel: $activeSlashPanel,
                    slashFeedbackMessage: $slashFeedbackMessage,
                    isSlashPanelLoading: isSlashPanelLoading,
                    isExecutingSlashAction: isExecutingSlashAction,
                    availableModels: availableModels,
                    selectedModelForEffort: $selectedModelForEffort,
                    resumeCandidates: resumeCandidates,
                    matchingSlashCommands: matchingSlashCommands,
                    inputPrompt: inputPrompt,
                    onSubmit: handleSubmit,
                    onHandleSlashCommand: handleSlashCommand,
                    onDismissSlashPanel: dismissSlashPanel,
                    onApplyModelSelection: applyModelSelection,
                    onApplyPermissionPreset: applyPermissionPreset,
                    onResumeRemoteThread: resumeRemoteThread
                )
            }
        }
        .task {
            remoteSessionMonitor.refreshHost(id: initialThread.hostId)
            await openThreadIfNeeded()
        }
        .onReceive(remoteSessionMonitor.$threads) { threads in
            if let updated = threads.first(where: { $0.stableId == thread.stableId }) {
                let countChanged = updated.history.count != thread.history.count
                let previousThreadId = thread.threadId
                let previousHistoryWasEmpty = thread.history.isEmpty
                if isAutoscrollPaused && updated.history.count > previousHistoryCount {
                    newMessageCount += updated.history.count - previousHistoryCount
                    previousHistoryCount = updated.history.count
                }
                thread = updated
                if countChanged && !isAutoscrollPaused {
                    shouldScrollToBottom = true
                }

                if (previousThreadId != updated.threadId || previousHistoryWasEmpty) && updated.needsHydration {
                    Task {
                        await openThreadIfNeeded()
                    }
                }
            }
        }
        .onChange(of: thread.canSendMessage) { _, canSend in
            if canSend && !isInputFocused {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isInputFocused = true
                }
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if thread.canSendMessage {
                    isInputFocused = true
                }
            }
        }
        .onChange(of: inputText) { _, newValue in
            if activeSlashPanel == nil,
               !newValue.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
                slashFeedbackMessage = nil
            }
        }
    }

    private var inputPrompt: String {
        if let connectionMessage = thread.connectionFeedbackMessage {
            return connectionMessage
        }
        if thread.canSteerTurn {
            return "Steer active turn..."
        }
        if thread.canStartTurn {
            if isPlanModeActive {
                return "Message remote Codex in Plan Mode..."
            }
            return "Message remote Codex..."
        }
        return "Remote thread is busy"
    }

    private func pauseAutoscroll() {
        isAutoscrollPaused = true
        previousHistoryCount = history.count
    }

    private func resumeAutoscroll() {
        isAutoscrollPaused = false
        newMessageCount = 0
        previousHistoryCount = history.count
    }

    private func handleSubmit() {
        guard let action = RemoteSlashCommand.submitAction(for: inputText) else { return }

        switch action {
        case .send(let text):
            submitPlainText(text)

        case .command(let command, let args):
            handleSlashCommand(command, args: args)

        case .rejectSlashCommand(let message):
            slashFeedbackMessage = message
        }
    }

    private func handleSlashCommand(_ command: RemoteSlashCommand, args: String?) {
        guard !command.requiresStartableThread || thread.canStartTurn else {
            slashFeedbackMessage = "'/\(command.bareName)' is disabled while a task is in progress."
            return
        }

        if args != nil && !command.supportsInlineArgs {
            slashFeedbackMessage = "Usage: \(command.rawValue)"
            return
        }

        inputText = ""
        resumeAutoscroll()
        slashFeedbackMessage = nil

        switch command {
        case .plan:
            Task {
                await activatePlanMode(andSubmit: args)
            }
        case .model:
            activeSlashPanel = .model
            selectedModelForEffort = nil
            Task {
                await loadModels()
            }
        case .permissions:
            activeSlashPanel = .permissions
        case .new:
            Task {
                await startNewRemoteThread()
            }
        case .resume:
            activeSlashPanel = .resume
            Task {
                await loadResumeCandidates()
            }
        }
    }

    private func dismissSlashPanel() {
        activeSlashPanel = nil
        selectedModelForEffort = nil
        isSlashPanelLoading = false
    }

    private func submitPlainText(_ text: String) {
        slashFeedbackMessage = nil
        resumeAutoscroll()
        shouldScrollToBottom = true

        Task {
            do {
                try await remoteSessionMonitor.sendMessage(thread: thread, text: text)
                await MainActor.run {
                    inputText = ""
                }
            } catch {
                await MainActor.run {
                    slashFeedbackMessage = error.localizedDescription
                }
            }
        }
    }

    private func openThreadIfNeeded() async {
        guard shouldLoadThreadDetails else { return }

        await MainActor.run {
            isOpeningThread = true
        }
        defer {
            Task { @MainActor in
                isOpeningThread = false
            }
        }

        do {
            let updated = try await remoteSessionMonitor.openThread(
                hostId: thread.hostId,
                threadId: thread.threadId
            )
            await MainActor.run {
                thread = updated
            }
        } catch {
            await MainActor.run {
                slashFeedbackMessage = error.localizedDescription
            }
        }
    }

    private func loadModels() async {
        await MainActor.run {
            isSlashPanelLoading = true
            availableModels = []
            selectedModelForEffort = nil
        }
        do {
            let models = try await remoteSessionMonitor.listModels(
                hostId: thread.hostId,
                includeHidden: true
            )
            await MainActor.run {
                availableModels = displayModels(from: models)
                isSlashPanelLoading = false
            }
        } catch {
            await MainActor.run {
                isSlashPanelLoading = false
                activeSlashPanel = nil
                slashFeedbackMessage = error.localizedDescription
            }
        }
    }

    private func displayModels(from models: [RemoteAppServerModel]) -> [RemoteAppServerModel] {
        let currentModel = thread.currentModel ?? thread.turnContext.model
        var visibleModels = models.filter { !$0.hidden }

        if let currentModel,
           !visibleModels.contains(where: { $0.model == currentModel }) {
            if let existingCurrent = models.first(where: { $0.model == currentModel }) {
                visibleModels.insert(existingCurrent, at: 0)
            } else {
                visibleModels.insert(syntheticCurrentModel(named: currentModel), at: 0)
            }
        }

        return visibleModels
    }

    private func syntheticCurrentModel(named model: String) -> RemoteAppServerModel {
        let effort = thread.currentReasoningEffort ?? .medium
        return RemoteAppServerModel(
            id: "current-\(model)",
            model: model,
            displayName: model.uppercased(),
            description: "Current thread model",
            hidden: false,
            supportedReasoningEfforts: [
                RemoteAppServerReasoningEffortOption(
                    reasoningEffort: effort,
                    description: "Current thread reasoning effort"
                )
            ],
            defaultReasoningEffort: effort,
            isDefault: false
        )
    }

    private func loadResumeCandidates() async {
        await MainActor.run {
            isSlashPanelLoading = true
            resumeCandidates = []
        }
        do {
            // Refresh first so the resume sheet reflects the latest remote
            // thread list instead of whichever snapshot happened to be cached
            // when the notch view was opened.
            try await remoteSessionMonitor.refreshHostNow(id: thread.hostId)
            let candidates = remoteSessionMonitor.availableThreads(
                hostId: thread.hostId,
                excluding: thread.threadId
            )
            await MainActor.run {
                resumeCandidates = candidates
                isSlashPanelLoading = false
            }
        } catch {
            await MainActor.run {
                isSlashPanelLoading = false
                activeSlashPanel = nil
                slashFeedbackMessage = error.localizedDescription
            }
        }
    }

    private func activatePlanMode(andSubmit args: String?) async {
        await MainActor.run {
            isExecutingSlashAction = true
        }
        defer {
            Task { @MainActor in
                isExecutingSlashAction = false
            }
        }

        do {
            let modes = try await remoteSessionMonitor.listCollaborationModes(hostId: thread.hostId)
            let planMask = modes.first(where: { $0.mode == .plan })
            let defaultMask = modes.first(where: { $0.mode == .default })
            let currentContext = thread.turnContext
            // Like the local chat view, bare /plan toggles the collaboration
            // mode for the next turn, while /plan <prompt> immediately sends a
            // prompt after the context update succeeds.
            let togglingOff = args == nil && isPlanModeActive

            if togglingOff {
                let effectiveModel = currentContext.effectiveModel ?? currentContext.model
                guard let effectiveModel else {
                    await MainActor.run {
                        slashFeedbackMessage = "Default mode is unavailable right now."
                    }
                    return
                }

                let effectiveEffort = currentContext.effectiveReasoningEffort ?? currentContext.reasoningEffort
                var updatedContext = currentContext
                updatedContext.model = defaultMask?.model ?? effectiveModel
                updatedContext.reasoningEffort = defaultMask?.reasoningEffort ?? effectiveEffort
                updatedContext.collaborationMode = RemoteAppServerCollaborationMode(
                    mode: .default,
                    settings: RemoteAppServerCollaborationSettings(
                        developerInstructions: nil,
                        model: updatedContext.model ?? effectiveModel,
                        reasoningEffort: updatedContext.reasoningEffort
                    )
                )

                let updatedThread = try await remoteSessionMonitor.setTurnContext(
                    thread: thread,
                    turnContext: updatedContext,
                    synchronizeThread: false
                )

                await MainActor.run {
                    thread = updatedThread
                    slashFeedbackMessage = "Plan mode disabled. Default mode will be used for the next turn."
                }
                return
            }

            let planModel = planMask?.model ?? currentContext.effectiveModel ?? currentContext.model
            let planEffort = planMask?.reasoningEffort ?? currentContext.effectiveReasoningEffort ?? currentContext.reasoningEffort

            guard let planModel else {
                await MainActor.run {
                    slashFeedbackMessage = "Plan mode is unavailable right now."
                }
                return
            }

            var updatedContext = currentContext
            updatedContext.model = planModel
            updatedContext.reasoningEffort = planEffort
            updatedContext.collaborationMode = RemoteAppServerCollaborationMode(
                mode: .plan,
                settings: RemoteAppServerCollaborationSettings(
                    developerInstructions: nil,
                    model: planModel,
                    reasoningEffort: planEffort
                )
            )

            let updatedThread = try await remoteSessionMonitor.setTurnContext(
                thread: thread,
                turnContext: updatedContext,
                synchronizeThread: false
            )

            await MainActor.run {
                thread = updatedThread
                slashFeedbackMessage = args == nil
                    ? "Plan mode enabled."
                    : nil
            }

            if let args, !args.isEmpty {
                try await remoteSessionMonitor.sendMessage(thread: updatedThread, text: args)
            }
        } catch {
            await MainActor.run {
                slashFeedbackMessage = error.localizedDescription
            }
        }
    }

    private func applyModelSelection(
        model: RemoteAppServerModel,
        effort: RemoteAppServerReasoningEffort
    ) async {
        await MainActor.run {
            isExecutingSlashAction = true
        }
        defer {
            Task { @MainActor in
                isExecutingSlashAction = false
            }
        }

        do {
            var updatedContext = thread.turnContext
            updatedContext.model = model.model
            updatedContext.reasoningEffort = effort
            if let collaborationMode = updatedContext.collaborationMode {
                updatedContext.collaborationMode = RemoteAppServerCollaborationMode(
                    mode: collaborationMode.mode,
                    settings: RemoteAppServerCollaborationSettings(
                        developerInstructions: collaborationMode.settings.developerInstructions,
                        model: model.model,
                        reasoningEffort: effort
                    )
                )
            }

            let updatedThread = try await remoteSessionMonitor.setTurnContext(
                thread: thread,
                turnContext: updatedContext,
                synchronizeThread: true
            )

            await MainActor.run {
                thread = updatedThread
                dismissSlashPanel()
                slashFeedbackMessage = nil
            }
        } catch {
            await MainActor.run {
                slashFeedbackMessage = error.localizedDescription
            }
        }
    }

    private func applyPermissionPreset(_ preset: RemoteApprovalPreset) async {
        await MainActor.run {
            isExecutingSlashAction = true
        }
        defer {
            Task { @MainActor in
                isExecutingSlashAction = false
            }
        }

        do {
            var updatedContext = thread.turnContext
            updatedContext.approvalPolicy = preset.approvalPolicy
            updatedContext.approvalsReviewer = .user
            updatedContext.sandboxPolicy = preset.sandboxPolicy

            let updatedThread = try await remoteSessionMonitor.setTurnContext(
                thread: thread,
                turnContext: updatedContext,
                synchronizeThread: true
            )
            remoteSessionMonitor.appendLocalInfoMessage(
                thread: updatedThread,
                message: "Permissions updated to \(preset.label)"
            )

            await MainActor.run {
                thread = updatedThread
                dismissSlashPanel()
                slashFeedbackMessage = nil
            }
        } catch {
            await MainActor.run {
                slashFeedbackMessage = error.localizedDescription
            }
        }
    }

    private func startNewRemoteThread() async {
        await MainActor.run {
            isExecutingSlashAction = true
        }
        defer {
            Task { @MainActor in
                isExecutingSlashAction = false
            }
        }

        do {
            // /new intentionally asks RemoteSessionMonitor for a brand-new
            // thread on the same host instead of cloning the current thread's
            // in-memory state. The returned thread becomes the new UI binding.
            let opened = try await remoteSessionMonitor.startFreshThread(hostId: thread.hostId)
            await MainActor.run {
                activeSlashPanel = nil
                slashFeedbackMessage = nil
                thread = opened
                viewModel.showRemoteChat(for: opened)
            }
        } catch {
            await MainActor.run {
                slashFeedbackMessage = error.localizedDescription
            }
        }
    }

    private func resumeRemoteThread(_ candidate: RemoteThreadState) async {
        await MainActor.run {
            isExecutingSlashAction = true
        }
        defer {
            Task { @MainActor in
                isExecutingSlashAction = false
            }
        }

        do {
            // Resuming always reopens by raw host/thread id so the view lands on
            // the remote monitor's canonical visible thread, even if the local
            // copy was only a lightweight candidate summary.
            let opened = try await remoteSessionMonitor.openThread(
                hostId: candidate.hostId,
                threadId: candidate.threadId
            )
            await MainActor.run {
                activeSlashPanel = nil
                slashFeedbackMessage = nil
                thread = opened
                viewModel.showRemoteChat(for: opened)
            }
        } catch {
            await MainActor.run {
                slashFeedbackMessage = error.localizedDescription
            }
        }
    }

    private func interrupt() {
        Task {
            try? await remoteSessionMonitor.interrupt(thread: thread)
        }
    }

    private func approve() {
        Task {
            try? await remoteSessionMonitor.approve(thread: thread)
        }
    }

    private func deny() {
        Task {
            try? await remoteSessionMonitor.deny(thread: thread)
        }
    }

    private func respondToApproval(_ action: PendingApprovalAction) {
        Task {
            try? await remoteSessionMonitor.respond(thread: thread, action: action)
        }
    }

    private func respondToQuestions(_ answers: PendingInteractionAnswerPayload) async -> Bool {
        guard case .userInput(let interaction)? = pendingInteraction else { return false }
        do {
            try await remoteSessionMonitor.respond(thread: thread, interaction: interaction, answers: answers)
            return true
        } catch {
            return false
        }
    }
}
