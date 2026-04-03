//
//  ChatView.swift
//  CodexIsland
//
//  Redesigned chat interface with clean visual hierarchy
//

import Combine
import SwiftUI

private enum LocalChatSubmitAction: Equatable {
    case send(String)
    case command(LocalSlashCommand, args: String?)
    case rejectSlashCommand(String)
}

private enum LocalSlashCommand: String, CaseIterable, Identifiable {
    case plan = "/plan"
    case model = "/model"
    case permissions = "/permissions"

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
        }
    }

    var supportsInlineArgs: Bool {
        self == .plan
    }

    static func matches(for text: String) -> [LocalSlashCommand] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return [] }
        let token = String(trimmed.dropFirst()).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        if token.isEmpty {
            return allCases
        }
        return allCases.filter { $0.bareName.hasPrefix(token.lowercased()) }
    }

    static func submitAction(for text: String) -> LocalChatSubmitAction? {
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
            return .rejectSlashCommand("Unsupported local command: \(trimmed)")
        }
        return .send(trimmed)
    }
}

private enum LocalSlashPanel: Equatable {
    case model
    case permissions
}

private struct LocalApprovalPreset: Identifiable, Equatable {
    let id: String
    let label: String
    let description: String
    let approvalPolicy: RemoteAppServerApprovalPolicy
    let sandboxPolicy: RemoteAppServerSandboxPolicy

    static let builtIn: [LocalApprovalPreset] = [
        LocalApprovalPreset(
            id: "read-only",
            label: "Read Only",
            description: "Codex can read files in the current workspace. Approval is required to edit files or access the internet.",
            approvalPolicy: .onRequest,
            sandboxPolicy: .readOnly()
        ),
        LocalApprovalPreset(
            id: "auto",
            label: "Default",
            description: "Codex can read and edit files in the current workspace, and run commands. Approval is required to access the internet or edit other files.",
            approvalPolicy: .onRequest,
            sandboxPolicy: .workspaceWrite()
        ),
        LocalApprovalPreset(
            id: "full-access",
            label: "Full Access",
            description: "Codex can edit files outside this workspace and access the internet without asking for approval.",
            approvalPolicy: .never,
            sandboxPolicy: .dangerFullAccess
        )
    ]
}

struct ChatView: View {
    let logicalSessionId: String
    let sessionMonitor: CodexSessionMonitor
    @ObservedObject var viewModel: NotchViewModel

    @State private var inputText: String = ""
    @State private var history: [ChatHistoryItem] = []
    @State private var session: SessionState
    @State private var isLoading: Bool = true
    @State private var isSending: Bool = false
    @State private var sendFailureMessage: String?
    @State private var shouldScrollToBottom: Bool = false
    @State private var isAutoscrollPaused: Bool = false
    @State private var newMessageCount: Int = 0
    @State private var previousHistoryCount: Int = 0
    @State private var isBottomVisible: Bool = true
    @State private var activeSlashPanel: LocalSlashPanel?
    @State private var slashFeedbackMessage: String?
    @State private var isSlashPanelLoading = false
    @State private var isExecutingSlashAction = false
    @State private var availableModels: [RemoteAppServerModel] = []
    @State private var selectedModelForEffort: RemoteAppServerModel?
    @FocusState private var isInputFocused: Bool

    init(logicalSessionId: String, initialSession: SessionState, sessionMonitor: CodexSessionMonitor, viewModel: NotchViewModel) {
        self.logicalSessionId = logicalSessionId
        self.sessionMonitor = sessionMonitor
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._session = State(initialValue: initialSession)

        // Initialize from cache if available (prevents loading flicker on view recreation)
        let cachedHistory = ChatHistoryManager.shared.history(for: logicalSessionId)
        let alreadyLoaded = ChatHistoryManager.shared.isLoaded(
            logicalSessionId: logicalSessionId,
            sessionId: initialSession.sessionId
        )
        self._history = State(initialValue: cachedHistory)
        self._isLoading = State(initialValue: !alreadyLoaded && cachedHistory.isEmpty)
    }

    private var pendingInteraction: PendingInteraction? {
        sessionMonitor.pendingInteraction(for: session)
    }

    private var hasPendingInteraction: Bool {
        pendingInteraction != nil
    }

    private var localAppServerThread: RemoteThreadState? {
        sessionMonitor.localAppServerThreads[session.sessionId]
    }

    private var matchingSlashCommands: [LocalSlashCommand] {
        guard activeSlashPanel == nil else { return [] }
        return LocalSlashCommand.matches(for: inputText)
    }

    private var isPlanModeActive: Bool {
        localAppServerThread?.turnContext.collaborationMode?.mode == .plan
    }

    private var trimmedInputText: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header
                chatHeader

                // Messages
                if isLoading {
                    loadingState
                } else if history.isEmpty {
                    emptyState
                } else {
                    messageList
                }

                if let sendFailureMessage {
                    inputStatusBanner(message: sendFailureMessage)
                        .transition(.opacity)
                }

                if let pendingInteraction {
                    PendingInteractionBar(
                        interaction: pendingInteraction,
                        canRespondInline: sessionMonitor.canRespondInline(to: session, interaction: pendingInteraction),
                        canOpenTerminal: session.canAttemptFocusTerminal,
                        onApprovalAction: { action in
                            respondToApproval(action)
                        },
                        onSubmitAnswers: { answers in
                            await respondToQuestions(answers)
                        },
                        onOpenTerminal: {
                            focusTerminal()
                        }
                    )
                    .id(pendingInteraction.id)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity
                    ))
                } else {
                    composer
                        .transition(.opacity)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: hasPendingInteraction)
        .animation(nil, value: viewModel.status)
        .task(id: session.sessionId) {
            await sessionMonitor.prepareAppServerThread(session: session)
            await ensureHistoryLoaded(for: session)
        }
        .onReceive(ChatHistoryManager.shared.$histories) { histories in
            // Update when count changes, last item differs, or content changes (e.g., tool status)
            if let newHistory = histories[logicalSessionId] {
                let countChanged = newHistory.count != history.count
                let lastItemChanged = newHistory.last?.id != history.last?.id
                // Always update - the @Published ensures we only get notified on real changes
                // This allows tool status updates (waitingForApproval -> running) to reflect
                if countChanged || lastItemChanged || newHistory != history {
                    // Track new messages when autoscroll is paused
                    if isAutoscrollPaused && newHistory.count > previousHistoryCount {
                        let addedCount = newHistory.count - previousHistoryCount
                        newMessageCount += addedCount
                        previousHistoryCount = newHistory.count
                    }

                    history = newHistory

                    // Auto-scroll to bottom only if autoscroll is NOT paused
                    if !isAutoscrollPaused && countChanged {
                        shouldScrollToBottom = true
                    }

                    // If we have data, skip loading state (handles view recreation)
                    if isLoading && !newHistory.isEmpty {
                        isLoading = false
                    }
                }

                if newHistory.isEmpty {
                    isLoading = !ChatHistoryManager.shared.isLoaded(
                        logicalSessionId: logicalSessionId,
                        sessionId: session.sessionId
                    )
                }
            } else if !sessionMonitor.instances.contains(where: { $0.logicalSessionId == logicalSessionId }) {
                viewModel.exitChat()
            }
        }
        .onReceive(sessionMonitor.$instances) { sessions in
            if let updated = sessions.first(where: { $0.logicalSessionId == logicalSessionId }),
               updated != session {
                let previousSession = session
                let hadPendingInteraction = hasPendingInteraction
                session = updated
                let isNowProcessing = updated.phase == .processing

                if hadPendingInteraction && updated.primaryPendingInteraction == nil && isNowProcessing {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        shouldScrollToBottom = true
                    }
                }

                let needsReload = !ChatHistoryManager.shared.isLoaded(
                    logicalSessionId: logicalSessionId,
                    sessionId: updated.sessionId
                ) && (
                    previousSession.sessionId != updated.sessionId ||
                    previousSession.transcriptPath != updated.transcriptPath
                )

                if needsReload {
                    Task {
                        await ensureHistoryLoaded(for: updated)
                    }
                }
            } else if !sessions.contains(where: { $0.logicalSessionId == logicalSessionId }) {
                viewModel.exitChat()
            }
        }
        .onChange(of: canSendMessages) { _, canSend in
            // Auto-focus input when tmux messaging becomes available
            if canSend && !isInputFocused {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isInputFocused = true
                }
            }
        }
        .onAppear {
            // Auto-focus input when chat opens and tmux messaging is available
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if canSendMessages {
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

    // MARK: - Header

    @State private var isHeaderHovered = false

    private var chatHeader: some View {
        Button {
            viewModel.exitChat()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(isHeaderHovered ? 1.0 : 0.6))
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(session.displayTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(isHeaderHovered ? 1.0 : 0.85))
                            .lineLimit(1)

                        if isPlanModeActive {
                            Text("PLAN MODE")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.black.opacity(0.9))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(TerminalColors.amber.opacity(0.95))
                                .clipShape(Capsule())
                        }
                    }

                    SessionStatusStrip(
                        model: session.currentModel,
                        reasoningEffort: session.currentReasoningEffort,
                        serviceTier: nil,
                        contextRemainingPercent: session.contextRemainingPercent
                    )
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHeaderHovered ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHeaderHovered = $0 }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.2))
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [fadeColor.opacity(0.7), fadeColor.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .offset(y: 24) // Push below header
            .allowsHitTesting(false)
        }
        .zIndex(1) // Render above message list
    }

    /// Whether the session is currently processing
    private var isProcessing: Bool {
        session.phase == .processing || session.phase == .compacting
    }

    /// Get the last user message ID for stable text selection per turn
    private var lastUserMessageId: String {
        for item in history.reversed() {
            if case .user = item.type {
                return item.id
            }
        }
        return ""
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.4)))
                .scaleEffect(0.8)
            Text("Loading messages...")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.2))
            Text("No messages yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func inputStatusBanner(message: String) -> some View {
        Text(message)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(TerminalColors.amber.opacity(0.92))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.18))
    }

    // MARK: - Message List

    /// Background color for fade gradients
    private let fadeColor = Color(red: 0.00, green: 0.00, blue: 0.00)

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 16) {
                    // Invisible anchor at bottom (first due to flip)
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")

                    // Processing indicator at bottom (first due to flip)
                    if isProcessing {
                        ProcessingIndicatorView(turnId: lastUserMessageId)
                            .padding(.horizontal, 16)
                            .scaleEffect(x: 1, y: -1)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.95)).combined(with: .offset(y: -4)),
                                removal: .opacity
                            ))
                    }

                    ForEach(history.reversed()) { item in
                        MessageItemView(item: item, sessionId: logicalSessionId)
                            .padding(.horizontal, 16)
                            .scaleEffect(x: 1, y: -1)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.98)),
                                removal: .opacity
                            ))
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 20)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isProcessing)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: history.count)
            }
            .scaleEffect(x: 1, y: -1)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Check if we're near the top of the content (which is bottom in inverted view)
                // contentOffset.y near 0 means at bottom, larger means scrolled up
                geometry.contentOffset.y < 50
            } action: { wasAtBottom, isNowAtBottom in
                if wasAtBottom && !isNowAtBottom {
                    // User scrolled away from bottom
                    pauseAutoscroll()
                } else if !wasAtBottom && isNowAtBottom && isAutoscrollPaused {
                    // User scrolled back to bottom
                    resumeAutoscroll()
                }
            }
            .onChange(of: shouldScrollToBottom) { _, shouldScroll in
                if shouldScroll {
                    withAnimation(.easeOut(duration: 0.3)) {
                        // In inverted scroll, use .bottom anchor to scroll to the visual bottom
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    shouldScrollToBottom = false
                    resumeAutoscroll()
                }
            }
            // New messages indicator overlay
            .overlay(alignment: .bottom) {
                if isAutoscrollPaused && newMessageCount > 0 {
                    NewMessagesIndicator(count: newMessageCount) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            // In inverted scroll, use .bottom anchor to scroll to the visual bottom
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        resumeAutoscroll()
                    }
                    .padding(.bottom, 16)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity
                    ))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isAutoscrollPaused && newMessageCount > 0)
        }
    }

    // MARK: - Input Bar

    /// Prefer app-server messaging for local Codex sessions and fall back to terminal when needed.
    private var canSendMessages: Bool {
        sessionMonitor.canSendMessage(to: session)
    }

    private var messagingPromptText: String {
        if canSendMessages {
            if isPlanModeActive {
                return "Message Codex in Plan Mode..."
            }
            return "Message Codex..."
        }

        if session.canAttemptFocusTerminal {
            return "Messaging unavailable. Open Terminal"
        }

        return "Waiting for Codex app-server"
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if isPlanModeActive {
                planModeBanner
            }

            if let activeSlashPanel {
                slashPanel(activeSlashPanel)
            } else if !matchingSlashCommands.isEmpty {
                slashSuggestionsPanel
            }

            if let slashFeedbackMessage, !slashFeedbackMessage.isEmpty {
                slashFeedbackBanner(message: slashFeedbackMessage)
            }

            inputBar
        }
    }

    private var planModeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(TerminalColors.amber)

            Text("Plan Mode active. `/plan` again will switch back to Default mode.")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.72))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
        )
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            if canSendMessages {
                TextField(messagingPromptText, text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .focused($isInputFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                            )
                    )
                    .onSubmit {
                        handleSubmit()
                    }

                Button {
                    handleSubmit()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(trimmedInputText.isEmpty || isSending ? .white.opacity(0.2) : .white.opacity(0.9))
                }
                .buttonStyle(.plain)
                .disabled(trimmedInputText.isEmpty || isSending)
            } else {
                Button {
                    if session.canAttemptFocusTerminal {
                        focusTerminal()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "terminal")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(session.canAttemptFocusTerminal ? .white.opacity(0.75) : .white.opacity(0.35))

                        Text(messagingPromptText)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(session.canAttemptFocusTerminal ? 0.65 : 0.4))

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color.white.opacity(0.04))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(!session.canAttemptFocusTerminal)

                Button {
                    focusTerminal()
                } label: {
                    Image(systemName: "arrow.up.forward.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(session.canAttemptFocusTerminal ? .white.opacity(0.9) : .white.opacity(0.2))
                }
                .buttonStyle(.plain)
                .disabled(!session.canAttemptFocusTerminal)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [fadeColor.opacity(0), fadeColor.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .offset(y: -24) // Push above input bar
            .allowsHitTesting(false)
        }
        .zIndex(1) // Render above message list
    }

    private var slashSuggestionsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Codex commands")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            ForEach(matchingSlashCommands) { command in
                Button {
                    handleSlashCommand(command, args: nil)
                } label: {
                    HStack(spacing: 10) {
                        Text(command.title)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.9))
                        Text(command.description)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.45))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.05))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func slashFeedbackBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundColor(TerminalColors.amber)

            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.7))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
        )
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func slashPanel(_ panel: LocalSlashPanel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title(for: panel))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.92))
                Text(subtitle(for: panel))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                Spacer()
                Button {
                    dismissSlashPanel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }

            if isSlashPanelLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading…")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.55))
                }
                .padding(.vertical, 8)
            } else {
                switch panel {
                case .model:
                    modelPanelContent
                case .permissions:
                    permissionsPanelContent
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var modelPanelContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selectedModelForEffort {
                Text("Choose reasoning effort for \(selectedModelForEffort.displayName)")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))

                ForEach(selectedModelForEffort.supportedReasoningEfforts, id: \.reasoningEffort) { option in
                    slashActionButton(
                        option.reasoningEffort.rawValue,
                        note: option.description
                    ) {
                        await applyModelSelection(
                            model: selectedModelForEffort,
                            effort: option.reasoningEffort
                        )
                    }
                }

                slashActionButton("Use default", note: selectedModelForEffort.defaultReasoningEffort.rawValue) {
                    await applyModelSelection(
                        model: selectedModelForEffort,
                        effort: selectedModelForEffort.defaultReasoningEffort
                    )
                }

                Button("Back") {
                    self.selectedModelForEffort = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
                .padding(.top, 4)
            } else if availableModels.isEmpty {
                Text("No models available")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
            } else {
                ForEach(availableModels, id: \.id) { model in
                    let isCurrent = model.model == (localAppServerThread?.currentModel ?? session.currentModel)
                    Button {
                        if model.supportedReasoningEfforts.count <= 1 {
                            Task {
                                await applyModelSelection(
                                    model: model,
                                    effort: model.defaultReasoningEffort
                                )
                            }
                        } else {
                            selectedModelForEffort = model
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(model.displayName)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.88))
                                if isCurrent {
                                    Text("Current")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.black)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.white.opacity(0.85))
                                        .clipShape(Capsule())
                                }
                                Spacer()
                                Text(model.defaultReasoningEffort.rawValue)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.35))
                            }
                            Text(model.description)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.4))
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.05))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isExecutingSlashAction)
                }
            }
        }
    }

    private var permissionsPanelContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(LocalApprovalPreset.builtIn) { preset in
                let currentContext = localAppServerThread?.turnContext
                let isCurrent = currentContext?.approvalPolicy == preset.approvalPolicy &&
                    currentContext?.sandboxPolicy == preset.sandboxPolicy
                Button {
                    Task {
                        await applyPermissionPreset(preset)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(preset.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.88))
                            if isCurrent {
                                Text("Current")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.white.opacity(0.85))
                                    .clipShape(Capsule())
                            }
                            Spacer()
                        }
                        Text(preset.description)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                            .lineLimit(3)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.05))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isExecutingSlashAction)
            }
        }
    }

    private func title(for panel: LocalSlashPanel) -> String {
        switch panel {
        case .model:
            return "/model"
        case .permissions:
            return "/permissions"
        }
    }

    private func subtitle(for panel: LocalSlashPanel) -> String {
        switch panel {
        case .model:
            return "Choose what model and reasoning effort to use."
        case .permissions:
            return "Choose what Codex is allowed to do."
        }
    }

    private func slashActionButton(
        _ title: String,
        note: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task {
                await action()
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                Text(note)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
        .disabled(isExecutingSlashAction)
    }

    // MARK: - Autoscroll Management

    /// Pause autoscroll (user scrolled away from bottom)
    private func pauseAutoscroll() {
        isAutoscrollPaused = true
        previousHistoryCount = history.count
    }

    /// Resume autoscroll and reset new message count
    private func resumeAutoscroll() {
        isAutoscrollPaused = false
        newMessageCount = 0
        previousHistoryCount = history.count
    }

    // MARK: - Actions

    private func focusTerminal() {
        guard let latestSession = latestSession() else { return }
        Task {
            _ = await TerminalFocusCoordinator.shared.focus(session: latestSession)
        }
    }

    private func respondToApproval(_ action: PendingApprovalAction) {
        guard let latestSession = latestSession() else { return }
        sessionMonitor.respond(sessionId: latestSession.sessionId, action: action)
    }

    private func respondToQuestions(_ answers: PendingInteractionAnswerPayload) async -> Bool {
        guard let latestSession = latestSession() else { return false }
        return await sessionMonitor.respond(sessionId: latestSession.sessionId, answers: answers)
    }

    private func handleSubmit() {
        guard !trimmedInputText.isEmpty, !isSending else { return }

        guard let action = LocalSlashCommand.submitAction(for: inputText) else { return }

        switch action {
        case .send(let text):
            Task {
                await attemptSendMessage(text)
            }

        case .command(let command, let args):
            handleSlashCommand(command, args: args)

        case .rejectSlashCommand(let message):
            slashFeedbackMessage = message
        }
    }

    @MainActor
    private func ensureHistoryLoaded(for session: SessionState) async {
        if ChatHistoryManager.shared.isLoaded(logicalSessionId: logicalSessionId, sessionId: session.sessionId) {
            history = ChatHistoryManager.shared.history(for: logicalSessionId)
            isLoading = false
            return
        }

        if history.isEmpty {
            isLoading = true
        }

        await ChatHistoryManager.shared.loadFromFile(
            logicalSessionId: logicalSessionId,
            sessionId: session.sessionId,
            cwd: session.cwd
        )

        history = ChatHistoryManager.shared.history(for: logicalSessionId)
        let hasResolvedInitialState =
            ChatHistoryManager.shared.isLoaded(logicalSessionId: logicalSessionId, sessionId: session.sessionId) ||
            !history.isEmpty ||
            session.transcriptPath != nil

        withAnimation(.easeOut(duration: 0.2)) {
            isLoading = !hasResolvedInitialState
        }
    }

    @MainActor
    private func attemptSendMessage(_ text: String) async {
        isSending = true
        let success = await sendToSession(text)
        isSending = false

        guard success else {
            showSendFailure("Session is still initializing. Please try again.")
            return
        }

        inputText = ""
        sendFailureMessage = nil
        slashFeedbackMessage = nil
        dismissSlashPanel()
        resumeAutoscroll()
        shouldScrollToBottom = true
    }

    private func handleSlashCommand(_ command: LocalSlashCommand, args: String?) {
        guard canSendMessages else {
            slashFeedbackMessage = "Waiting for Codex app-server"
            return
        }

        if args != nil && !command.supportsInlineArgs {
            slashFeedbackMessage = "Usage: \(command.rawValue)"
            return
        }

        inputText = ""
        resumeAutoscroll()
        sendFailureMessage = nil
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
        }
    }

    private func sendToSession(_ text: String) async -> Bool {
        guard let latestSession = latestSession() else {
            return false
        }

        return await sessionMonitor.sendMessage(sessionId: latestSession.sessionId, text: text)
    }

    private func latestSession() -> SessionState? {
        sessionMonitor.instances.first(where: { $0.logicalSessionId == logicalSessionId }) ?? session
    }

    private func dismissSlashPanel() {
        activeSlashPanel = nil
        selectedModelForEffort = nil
        isSlashPanelLoading = false
    }

    private func loadModels() async {
        guard let latestSession = latestSession() else { return }

        await MainActor.run {
            isSlashPanelLoading = true
            availableModels = []
            selectedModelForEffort = nil
        }

        do {
            let models = try await sessionMonitor.listLocalModels(
                sessionId: latestSession.sessionId,
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
        let currentModel = localAppServerThread?.currentModel ?? session.currentModel
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
        let effort = localAppServerThread?.currentReasoningEffort ?? .medium
        return RemoteAppServerModel(
            id: "current-\(model)",
            model: model,
            displayName: model.uppercased(),
            description: "Current session model",
            hidden: false,
            supportedReasoningEfforts: [
                RemoteAppServerReasoningEffortOption(
                    reasoningEffort: effort,
                    description: "Current session reasoning effort"
                )
            ],
            defaultReasoningEffort: effort,
            isDefault: false
        )
    }

    private func activatePlanMode(andSubmit args: String?) async {
        guard let latestSession = latestSession() else { return }

        await MainActor.run {
            isExecutingSlashAction = true
        }
        defer {
            Task { @MainActor in
                isExecutingSlashAction = false
            }
        }

        do {
            let currentThread = try await sessionMonitor.requireLocalAppServerThread(sessionId: latestSession.sessionId)
            let modes = try await sessionMonitor.listLocalCollaborationModes(sessionId: latestSession.sessionId)
            let planMask = modes.first(where: { $0.mode == .plan })
            let defaultMask = modes.first(where: { $0.mode == .default })
            let currentContext = currentThread.turnContext
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

                _ = try await sessionMonitor.setLocalTurnContext(
                    sessionId: latestSession.sessionId,
                    turnContext: updatedContext,
                    synchronizeThread: false
                )

                await MainActor.run {
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

            _ = try await sessionMonitor.setLocalTurnContext(
                sessionId: latestSession.sessionId,
                turnContext: updatedContext,
                synchronizeThread: false
            )

            await MainActor.run {
                slashFeedbackMessage = args == nil ? "Plan mode enabled." : nil
            }

            if let args, !args.isEmpty {
                let sent = await sessionMonitor.sendMessage(sessionId: latestSession.sessionId, text: args)
                if !sent {
                    await MainActor.run {
                        slashFeedbackMessage = "Session is still initializing. Please try again."
                    }
                }
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
        guard let latestSession = latestSession() else { return }

        await MainActor.run {
            isExecutingSlashAction = true
        }
        defer {
            Task { @MainActor in
                isExecutingSlashAction = false
            }
        }

        do {
            let currentThread = try await sessionMonitor.requireLocalAppServerThread(sessionId: latestSession.sessionId)
            var updatedContext = currentThread.turnContext
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

            _ = try await sessionMonitor.setLocalTurnContext(
                sessionId: latestSession.sessionId,
                turnContext: updatedContext,
                synchronizeThread: true
            )

            await MainActor.run {
                dismissSlashPanel()
                slashFeedbackMessage = nil
            }
        } catch {
            await MainActor.run {
                slashFeedbackMessage = error.localizedDescription
            }
        }
    }

    private func applyPermissionPreset(_ preset: LocalApprovalPreset) async {
        guard let latestSession = latestSession() else { return }

        await MainActor.run {
            isExecutingSlashAction = true
        }
        defer {
            Task { @MainActor in
                isExecutingSlashAction = false
            }
        }

        do {
            let currentThread = try await sessionMonitor.requireLocalAppServerThread(sessionId: latestSession.sessionId)
            var updatedContext = currentThread.turnContext
            updatedContext.approvalPolicy = preset.approvalPolicy
            updatedContext.approvalsReviewer = .user
            updatedContext.sandboxPolicy = preset.sandboxPolicy

            _ = try await sessionMonitor.setLocalTurnContext(
                sessionId: latestSession.sessionId,
                turnContext: updatedContext,
                synchronizeThread: true
            )

            await MainActor.run {
                dismissSlashPanel()
                slashFeedbackMessage = nil
            }
        } catch {
            await MainActor.run {
                slashFeedbackMessage = error.localizedDescription
            }
        }
    }

    private func showSendFailure(_ message: String) {
        sendFailureMessage = message

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if sendFailureMessage == message {
                sendFailureMessage = nil
            }
        }
    }
}

// MARK: - Message Item View

struct MessageItemView: View {
    let item: ChatHistoryItem
    let sessionId: String

    var body: some View {
        switch item.type {
        case .user(let text):
            UserMessageView(text: text)
        case .assistant(let text):
            AssistantMessageView(text: text)
        case .toolCall(let tool):
            ToolCallView(tool: tool, sessionId: sessionId)
        case .thinking(let text):
            ThinkingView(text: text)
        case .interrupted:
            InterruptedMessageView()
        }
    }
}

// MARK: - User Message

struct UserMessageView: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 60)

            MarkdownText(text, color: .white, fontSize: 13)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.white.opacity(0.15))
                )
        }
    }
}

// MARK: - Assistant Message

struct AssistantMessageView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // White dot indicator
            Circle()
                .fill(Color.white.opacity(0.6))
                .frame(width: 6, height: 6)
                .padding(.top, 5)

            MarkdownText(text, color: .white.opacity(0.9), fontSize: 13)

            Spacer(minLength: 60)
        }
    }
}

// MARK: - Processing Indicator

struct ProcessingIndicatorView: View {
    private let baseTexts = ["Processing", "Working"]
    private let color = TerminalColors.prompt
    private let baseText: String

    @State private var dotCount: Int = 1
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    /// Use a turnId to select text consistently per user turn
    init(turnId: String = "") {
        // Use hash of turnId to pick base text consistently for this turn
        let index = abs(turnId.hashValue) % baseTexts.count
        baseText = baseTexts[index]
    }

    private var dots: String {
        String(repeating: ".", count: dotCount)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            ProcessingSpinner()
                .frame(width: 6)

            Text(baseText + dots)
                .font(.system(size: 13))
                .foregroundColor(color)

            Spacer()
        }
        .onReceive(timer) { _ in
            dotCount = (dotCount % 3) + 1
        }
    }
}

// MARK: - Tool Call View

struct ToolCallView: View {
    let tool: ToolCallItem
    let sessionId: String

    @State private var pulseOpacity: Double = 0.6
    @State private var isExpanded: Bool = false
    @State private var isHovering: Bool = false

    private var statusColor: Color {
        switch tool.status {
        case .running:
            return Color.white
        case .waitingForApproval:
            return TerminalColors.amber
        case .success:
            return Color.green
        case .error, .interrupted:
            return Color.red
        }
    }

    private var textColor: Color {
        switch tool.status {
        case .running:
            return .white.opacity(0.6)
        case .waitingForApproval:
            return TerminalColors.amber.opacity(0.9)
        case .success:
            return .white.opacity(0.7)
        case .error, .interrupted:
            return Color.red.opacity(0.8)
        }
    }

    private var hasResult: Bool {
        tool.result != nil || tool.structuredResult != nil
    }

    /// Whether the tool can be expanded (has result, NOT Task tools, NOT Edit tools)
    private var canExpand: Bool {
        tool.name != "Task" && tool.name != "Edit" && hasResult
    }

    private var showContent: Bool {
        tool.name == "Edit" || isExpanded
    }

    private var agentDescription: String? {
        guard tool.name == "AgentOutputTool",
              let agentId = tool.input["agentId"],
              let sessionDescriptions = ChatHistoryManager.shared.agentDescriptions[sessionId] else {
            return nil
        }
        return sessionDescriptions[agentId]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor.opacity(tool.status == .running || tool.status == .waitingForApproval ? pulseOpacity : 0.6))
                    .frame(width: 6, height: 6)
                    .id(tool.status)  // Forces view recreation, cancelling repeatForever animation
                    .onAppear {
                        if tool.status == .running || tool.status == .waitingForApproval {
                            startPulsing()
                        }
                    }

                // Tool name (formatted for MCP tools)
                Text(MCPToolFormatter.formatToolName(tool.name))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(textColor)
                    .fixedSize()

                if tool.name == "Task" && !tool.subagentTools.isEmpty {
                    let taskDesc = tool.input["description"] ?? "Running agent..."
                    Text("\(taskDesc) (\(tool.subagentTools.count) tools)")
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if tool.name == "AgentOutputTool", let desc = agentDescription {
                    let blocking = tool.input["block"] == "true"
                    Text(blocking ? "Waiting: \(desc)" : desc)
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if MCPToolFormatter.isMCPTool(tool.name) && !tool.input.isEmpty {
                    Text(MCPToolFormatter.formatArgs(tool.input))
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(tool.statusDisplay.text)
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                // Expand indicator (only for expandable tools)
                if canExpand && tool.status != .running && tool.status != .waitingForApproval {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.3))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
                }
            }

            // Subagent tools list (for Task tools)
            if tool.name == "Task" && !tool.subagentTools.isEmpty {
                SubagentToolsList(tools: tool.subagentTools)
                    .padding(.leading, 12)
                    .padding(.top, 2)
            }

            // Result content (Edit always shows, others when expanded)
            // Edit tools bypass hasResult check - fallback in ToolResultContent renders from input params
            if showContent && tool.status != .running && tool.name != "Task" && (hasResult || tool.name == "Edit") {
                ToolResultContent(tool: tool)
                    .padding(.leading, 12)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Edit tools show diff from input even while running
            if tool.name == "Edit" && tool.status == .running {
                EditInputDiffView(input: tool.input)
                    .padding(.leading, 12)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(canExpand && isHovering ? Color.white.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            if canExpand {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
    }

    private func startPulsing() {
        withAnimation(
            .easeInOut(duration: 0.6)
            .repeatForever(autoreverses: true)
        ) {
            pulseOpacity = 0.15
        }
    }
}

// MARK: - Subagent Views

/// List of subagent tools (shown during Task execution)
struct SubagentToolsList: View {
    let tools: [SubagentToolCall]

    /// Number of hidden tools (all except last 2)
    private var hiddenCount: Int {
        max(0, tools.count - 2)
    }

    /// Recent tools to show (last 2, regardless of status)
    private var recentTools: [SubagentToolCall] {
        Array(tools.suffix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Show count of older hidden tools at top
            if hiddenCount > 0 {
                Text("+\(hiddenCount) more tool uses")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }

            // Show last 2 tools (most recent activity)
            ForEach(recentTools) { tool in
                SubagentToolRow(tool: tool)
            }
        }
    }
}

/// Single subagent tool row
struct SubagentToolRow: View {
    let tool: SubagentToolCall

    @State private var dotOpacity: Double = 0.5

    private var statusColor: Color {
        switch tool.status {
        case .running: return TerminalColors.prompt
        case .waitingForApproval: return TerminalColors.amber
        case .success: return .green
        case .error, .interrupted: return .red
        }
    }

    /// Get status text using the same logic as regular tools
    private var statusText: String {
        if tool.status == .interrupted {
            return "Interrupted"
        } else if tool.status == .running {
            return ToolStatusDisplay.running(for: tool.name, input: tool.input).text
        } else {
            // For completed subagent tools, we don't have the result data
            // so use a simple display based on tool name and input
            return ToolStatusDisplay.running(for: tool.name, input: tool.input).text
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            // Status dot
            Circle()
                .fill(statusColor.opacity(tool.status == .running ? dotOpacity : 0.6))
                .frame(width: 4, height: 4)
                .id(tool.status)  // Forces view recreation, cancelling repeatForever animation
                .onAppear {
                    if tool.status == .running {
                        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                            dotOpacity = 0.2
                        }
                    }
                }

            // Tool name
            Text(tool.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            // Status text (same format as regular tools)
            Text(statusText)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Summary of subagent tools (shown when Task is expanded after completion)
struct SubagentToolsSummary: View {
    let tools: [SubagentToolCall]

    private var toolCounts: [(String, Int)] {
        var counts: [String: Int] = [:]
        for tool in tools {
            counts[tool.name, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Subagent used \(tools.count) tools:")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            HStack(spacing: 8) {
                ForEach(toolCounts.prefix(5), id: \.0) { name, count in
                    HStack(spacing: 2) {
                        Text(name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                        Text("×\(count)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.03))
        )
    }
}

// MARK: - Thinking View

struct ThinkingView: View {
    let text: String

    @State private var isExpanded = false

    private var canExpand: Bool {
        text.count > 80
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(Color.gray.opacity(0.5))
                .frame(width: 6, height: 6)
                .padding(.top, 4)

            Text(isExpanded ? text : String(text.prefix(80)) + (canExpand ? "..." : ""))
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .italic()
                .lineLimit(isExpanded ? nil : 1)
                .multilineTextAlignment(.leading)

            Spacer()

            if canExpand {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.gray.opacity(0.5))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .padding(.top, 3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if canExpand {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

// MARK: - Interrupted Message

struct InterruptedMessageView: View {
    var body: some View {
        HStack {
            Text("Interrupted")
                .font(.system(size: 13))
                .foregroundColor(.red)
            Spacer()
        }
    }
}

// MARK: - Chat Interactive Prompt Bar

struct PendingInteractionBar: View {
    let interaction: PendingInteraction
    let canRespondInline: Bool
    let canOpenTerminal: Bool
    let onApprovalAction: (PendingApprovalAction) -> Void
    let onSubmitAnswers: (PendingInteractionAnswerPayload) async -> Bool
    let onOpenTerminal: () -> Void

    @State private var currentQuestionIndex = 0
    @State private var selectedAnswers: [String: String] = [:]
    @State private var textAnswer = ""
    @State private var isSubmitting = false

    @State private var showContent = false
    @State private var showButton = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .opacity(showContent ? 1 : 0)
                .offset(x: showContent ? 0 : -10)

            switch interaction {
            case .approval(let approval):
                approvalActions(approval)
                    .opacity(showButton ? 1 : 0)
                    .scaleEffect(showButton ? 1 : 0.95)
            case .userInput(let request):
                userInputContent(request)
                    .opacity(showButton ? 1 : 0)
                    .scaleEffect(showButton ? 1 : 0.95)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showContent = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.1)) {
                showButton = true
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(MCPToolFormatter.formatToolName(interaction.title))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(TerminalColors.amber)

            Text(interaction.summaryText)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.55))
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private func approvalActions(_ approval: PendingApprovalInteraction) -> some View {
        HStack(spacing: 8) {
            ForEach(approval.availableActions, id: \.self) { action in
                Button {
                    onApprovalAction(action)
                } label: {
                    Text(action.buttonTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(action == .allow ? .black : .white.opacity(0.75))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(action == .allow ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func userInputContent(_ request: PendingUserInputInteraction) -> some View {
        let presentationMode = request.presentationMode(canRespondInline: canRespondInline)

        if presentationMode == .terminalOnly {
            terminalShortcutButton()
        } else if let question = request.questions[safe: currentQuestionIndex] {
            let isReadOnly = presentationMode == .readOnly
            VStack(alignment: .leading, spacing: 10) {
                if request.questions.count > 1 {
                    Text("Question \(currentQuestionIndex + 1) / \(request.questions.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.35))
                }

                Text(question.question)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))

                if question.isChoiceQuestion {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                            Button {
                                guard !isReadOnly else { return }
                                selectedAnswers[question.id] = option.label
                                Task {
                                    await advanceOrSubmit(request: request)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.white)
                                    if let description = option.description, !description.isEmpty {
                                        Text(description)
                                            .font(.system(size: 10))
                                            .foregroundColor(.white.opacity(0.45))
                                            .lineLimit(2)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.white.opacity(0.08))
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isSubmitting || isReadOnly)
                        }

                        if question.isOther {
                            HStack(spacing: 10) {
                                TextField("Other answer", text: $textAnswer)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 18)
                                            .fill(Color.white.opacity(0.08))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 18)
                                                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                                            )
                                    )
                                    .disabled(isReadOnly || isSubmitting)
                                    .onSubmit {
                                        guard !isReadOnly else { return }
                                        guard !textAnswer.isEmpty else { return }
                                        selectedAnswers[question.id] = textAnswer
                                        Task {
                                            await advanceOrSubmit(request: request)
                                        }
                                    }

                                Button {
                                    guard !isReadOnly else { return }
                                    selectedAnswers[question.id] = textAnswer
                                    Task {
                                        await advanceOrSubmit(request: request)
                                    }
                                } label: {
                                    Text(currentQuestionIndex + 1 == request.questions.count ? "Send" : "Next")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.black)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(Color.white.opacity(textAnswer.isEmpty ? 0.2 : 0.95))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .disabled(isReadOnly || textAnswer.isEmpty || isSubmitting)
                            }
                        }

                        if isReadOnly {
                            terminalFallbackHint
                            terminalShortcutButton(alignment: .leading)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            TextField("Type your answer", text: $textAnswer)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 18)
                                        .fill(Color.white.opacity(0.08))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 18)
                                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                                        )
                                )
                                .disabled(isReadOnly || isSubmitting)
                                .onSubmit {
                                    guard !isReadOnly else { return }
                                    selectedAnswers[question.id] = textAnswer
                                    Task {
                                        await advanceOrSubmit(request: request)
                                    }
                                }

                            Button {
                                guard !isReadOnly else { return }
                                selectedAnswers[question.id] = textAnswer
                                Task {
                                    await advanceOrSubmit(request: request)
                                }
                            } label: {
                                Text(currentQuestionIndex + 1 == request.questions.count ? "Send" : "Next")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(Color.white.opacity(textAnswer.isEmpty ? 0.2 : 0.95))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(isReadOnly || textAnswer.isEmpty || isSubmitting)
                        }

                        if isReadOnly {
                            terminalFallbackHint
                            terminalShortcutButton(alignment: .leading)
                        }
                    }
                }

                if isSubmitting {
                    Text("Sending answer...")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
        }
    }

    private var terminalFallbackHint: some View {
        Text("Inline reply is unavailable for this session. Open Terminal to answer there.")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(0.4))
    }

    @ViewBuilder
    private func terminalShortcutButton(alignment: HorizontalAlignment = .trailing) -> some View {
        HStack {
            if alignment == .trailing {
                Spacer()
            }

            Button {
                if canOpenTerminal {
                    onOpenTerminal()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .medium))
                    Text("Terminal")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(canOpenTerminal ? .black : .white.opacity(0.4))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(canOpenTerminal ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            if alignment == .leading {
                Spacer()
            }
        }
    }

    private func advanceOrSubmit(request: PendingUserInputInteraction) async {
        guard let question = request.questions[safe: currentQuestionIndex] else { return }
        guard let value = selectedAnswers[question.id] else { return }

        isSubmitting = true
        defer { isSubmitting = false }

        if request.transport.isLocalCodex {
            let success = await onSubmitAnswers(PendingInteractionAnswerPayload(
                answers: [question.id: value.isEmpty ? [] : [value]]
            ))
            guard success else { return }

            if currentQuestionIndex + 1 < request.questions.count {
                currentQuestionIndex += 1
                textAnswer = selectedAnswers[request.questions[currentQuestionIndex].id] ?? ""
            }
            return
        }

        if currentQuestionIndex + 1 < request.questions.count {
            currentQuestionIndex += 1
            textAnswer = selectedAnswers[request.questions[currentQuestionIndex].id] ?? ""
            return
        }

        var answers: [String: [String]] = [:]
        for question in request.questions {
            if let answer = selectedAnswers[question.id], !answer.isEmpty {
                answers[question.id] = [answer]
            } else {
                answers[question.id] = []
            }
        }
        _ = await onSubmitAnswers(PendingInteractionAnswerPayload(answers: answers))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

// MARK: - Chat Approval Bar

/// Approval bar for the chat view with animated buttons
struct ChatApprovalBar: View {
    let tool: String
    let toolInput: String?
    let onApprove: () -> Void
    let onDeny: () -> Void

    @State private var showContent = false
    @State private var showAllowButton = false
    @State private var showDenyButton = false

    var body: some View {
        HStack(spacing: 12) {
            // Tool info
            VStack(alignment: .leading, spacing: 2) {
                Text(MCPToolFormatter.formatToolName(tool))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(TerminalColors.amber)
                if let input = toolInput {
                    Text(input)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .opacity(showContent ? 1 : 0)
            .offset(x: showContent ? 0 : -10)

            Spacer()

            // Deny button
            Button {
                onDeny()
            } label: {
                Text("Deny")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showDenyButton ? 1 : 0)
            .scaleEffect(showDenyButton ? 1 : 0.8)

            // Allow button
            Button {
                onApprove()
            } label: {
                Text("Allow")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.95))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showAllowButton ? 1 : 0)
            .scaleEffect(showAllowButton ? 1 : 0.8)
        }
        .frame(minHeight: 44)  // Consistent height with other bars
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showContent = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.1)) {
                showDenyButton = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.15)) {
                showAllowButton = true
            }
        }
    }
}

// MARK: - New Messages Indicator

/// Floating indicator showing count of new messages when user has scrolled up
struct NewMessagesIndicator: View {
    let count: Int
    let onTap: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))

                Text(count == 1 ? "1 new message" : "\(count) new messages")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(TerminalColors.prompt)
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
            )
            .scaleEffect(isHovering ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                isHovering = hovering
            }
        }
    }
}
