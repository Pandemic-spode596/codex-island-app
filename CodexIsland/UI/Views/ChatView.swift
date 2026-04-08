//
//  ChatView.swift
//  CodexIsland
//
//  Redesigned chat interface with clean visual hierarchy
//

import Combine
import SwiftUI

enum LocalChatSubmitAction: Equatable {
    case send(String)
    case command(LocalSlashCommand, args: String?)
    case rejectSlashCommand(String)
}

// Local slash commands are implemented entirely on top of the local app-server
// session layer. They never travel through transcript parsing, so the view must
// decide up front whether to send a user turn or open a configuration panel.
enum LocalSlashCommand: String, CaseIterable, Identifiable {
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
            return "新建空白本地会话"
        case .resume:
            return "恢复保存的本地线程"
        }
    }

    var supportsInlineArgs: Bool {
        self == .plan
    }

    var requiresStartableSession: Bool {
        switch self {
        case .plan, .model, .permissions:
            return true
        case .new, .resume:
            return false
        }
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

enum LocalSlashPanel: Equatable {
    case model
    case permissions
    case resume
}

struct LocalApprovalPreset: Identifiable, Equatable {
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
    let preferredSessionId: String
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
    @State private var resumeCandidates: [SessionState] = []
    @FocusState private var isInputFocused: Bool

    init(
        logicalSessionId: String,
        preferredSessionId: String,
        initialSession: SessionState,
        sessionMonitor: CodexSessionMonitor,
        viewModel: NotchViewModel
    ) {
        self.logicalSessionId = logicalSessionId
        self.preferredSessionId = preferredSessionId
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
        sessionMonitor.localAppServerThread(for: session)
    }

    private var matchingSlashCommands: [LocalSlashCommand] {
        guard activeSlashPanel == nil else { return [] }
        return LocalSlashCommand.matches(for: inputText)
    }

    private var isPlanModeActive: Bool {
        localAppServerThread?.turnContext.collaborationMode?.mode == .plan
    }

    private var shouldShowDebugConversationID: Bool {
        AppSettings.remoteDiagnosticsLoggingEnabled
    }

    private var debugConversationID: String {
        let candidate = localAppServerThread?.threadId ?? session.sessionId
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? session.sessionId : trimmed
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
            if applyPreferredHistory(from: latestSession() ?? session) {
                return
            }
            await ensureHistoryLoaded(for: session)
        }
        .onReceive(ChatHistoryManager.shared.$histories) { histories in
            if sessionMonitor.prefersAppServerHistory(for: session) {
                _ = applyPreferredHistory(from: latestSession() ?? session)
                return
            }

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
            } else if currentSession(in: sessionMonitor.instances) == nil {
                viewModel.exitChat()
            }
        }
        .onReceive(sessionMonitor.$instances) { sessions in
            if let updated = currentSession(in: sessions),
               updated != session {
                let previousSession = session
                let hadPendingInteraction = hasPendingInteraction
                session = updated
                let isNowProcessing = updated.phase == .processing

                if applyPreferredHistory(from: updated) {
                    return
                }

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
            } else if currentSession(in: sessions) == nil {
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

                    if shouldShowDebugConversationID {
                        DebugConversationIDView(
                            label: "Session ID",
                            value: debugConversationID
                        )
                    }
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

    /// Local Codex messaging is app-server only.
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

        if session.provider == .codex {
            if localAppServerThread == nil {
                return "Waiting for Codex app-server"
            }
            if pendingInteraction != nil {
                return "Resolve the current Codex interaction above"
            }
            return "Codex is busy"
        }

        if session.canAttemptFocusTerminal {
            return "Messaging unavailable. Open Terminal"
        }

        return "Waiting for terminal access"
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
                case .resume:
                    resumePanelContent
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

    private var resumePanelContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if resumeCandidates.isEmpty {
                Text("No other local threads available")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
            } else {
                ForEach(resumeCandidates) { candidate in
                    Button {
                        Task {
                            await resumeLocalThread(candidate)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(candidate.displayTitle)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.88))
                                    .lineLimit(1)
                                Spacer()
                                Text(candidate.lastActivity.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.35))
                            }
                            Text(candidate.cwd)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.4))
                                .lineLimit(1)
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

    private func title(for panel: LocalSlashPanel) -> String {
        switch panel {
        case .model:
            return "/model"
        case .permissions:
            return "/permissions"
        case .resume:
            return "/resume"
        }
    }

    private func subtitle(for panel: LocalSlashPanel) -> String {
        switch panel {
        case .model:
            return "Choose what model and reasoning effort to use."
        case .permissions:
            return "Choose what Codex is allowed to do."
        case .resume:
            return "Resume a saved local chat."
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
        Task {
            let result = await sessionMonitor.respond(sessionId: latestSession.sessionId, action: action)
            guard case .sent = result else {
                await MainActor.run {
                    showSendFailure(sendFailureMessage(for: result))
                }
                return
            }
        }
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
        if applyPreferredHistory(from: session) {
            return
        }

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
        if let loadFailure = ChatHistoryManager.shared.loadFailure(
            logicalSessionId: logicalSessionId,
            sessionId: session.sessionId
        ) {
            sendFailureMessage = loadFailure
            withAnimation(.easeOut(duration: 0.2)) {
                isLoading = false
            }
            return
        }
        let hasResolvedInitialState =
            ChatHistoryManager.shared.isLoaded(logicalSessionId: logicalSessionId, sessionId: session.sessionId) ||
            !history.isEmpty ||
            session.transcriptPath != nil

        withAnimation(.easeOut(duration: 0.2)) {
            isLoading = !hasResolvedInitialState
        }
    }

    @MainActor
    @discardableResult
    private func applyPreferredHistory(from session: SessionState) -> Bool {
        guard let preferredHistory = sessionMonitor.preferredHistory(for: session) else {
            return false
        }

        let countChanged = preferredHistory.count != history.count
        if preferredHistory != history {
            if isAutoscrollPaused && preferredHistory.count > previousHistoryCount {
                let addedCount = preferredHistory.count - previousHistoryCount
                newMessageCount += addedCount
                previousHistoryCount = preferredHistory.count
            }

            history = preferredHistory

            if !isAutoscrollPaused && countChanged {
                shouldScrollToBottom = true
            }
        }

        if isLoading {
            isLoading = false
        }

        return true
    }

    @MainActor
    private func attemptSendMessage(_ text: String) async {
        isSending = true
        let result = await sendToSession(text)
        isSending = false

        guard case .sent = result else {
            showSendFailure(sendFailureMessage(for: result))
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
        // /plan, /model, and /permissions all mutate turn context on the
        // currently selected local app-server thread, so they are disabled
        // while a turn is running. /new and /resume operate at the thread layer
        // and stay available even when the visible session is synthetic.
        let canConfigureSession = localAppServerThread?.canStartTurn ?? canSendMessages
        if command.requiresStartableSession && !canConfigureSession {
            slashFeedbackMessage = "'/\(command.bareName)' is disabled while a task is in progress."
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
        case .new:
            Task {
                await startNewLocalThread()
            }
        case .resume:
            activeSlashPanel = .resume
            Task {
                await loadResumeCandidates()
            }
        }
    }

    private func sendToSession(_ text: String) async -> CodexSessionMonitor.LocalSendResult {
        guard let latestSession = latestSession() else {
            return .failed("Session is unavailable for messaging.")
        }

        return await sessionMonitor.sendMessageResult(sessionId: latestSession.sessionId, text: text)
    }

    private func sendFailureMessage(for result: CodexSessionMonitor.LocalSendResult) -> String {
        switch result {
        case .sent:
            return ""
        case .initializing:
            return "Session is still initializing. Please try again."
        case .failed(let message):
            return message
        }
    }

    private func latestSession() -> SessionState? {
        currentSession(in: sessionMonitor.instances) ?? session
    }

    private func currentSession(in sessions: [SessionState]) -> SessionState? {
        sessions.first(where: { $0.sessionId == preferredSessionId }) ??
            sessions.first(where: { $0.logicalSessionId == logicalSessionId })
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

    private func loadResumeCandidates() async {
        guard let latestSession = latestSession() else { return }

        await MainActor.run {
            isSlashPanelLoading = true
            resumeCandidates = []
        }

        let candidates = sessionMonitor.availableLocalThreads(excluding: latestSession.sessionId)
            .filter { $0.sessionId != latestSession.sessionId }

        await MainActor.run {
            resumeCandidates = candidates
            isSlashPanelLoading = false
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
            // Bare /plan acts as a toggle between the server's plan/default
            // collaboration masks. /plan <prompt> first switches to plan mode
            // and then immediately submits the inline prompt as the next turn.
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
                let sendResult = await sessionMonitor.sendMessageResult(
                    sessionId: latestSession.sessionId,
                    text: args
                )
                if case .sent = sendResult {
                    return
                } else {
                    await MainActor.run {
                        slashFeedbackMessage = sendFailureMessage(for: sendResult)
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

    private func startNewLocalThread() async {
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
            // Keep the cwd from the current logical session so /new creates a
            // blank thread in the same workspace instead of dropping the user
            // back to the local app-server default directory.
            let opened = try await sessionMonitor.startFreshLocalThread(cwd: latestSession.cwd)
            await MainActor.run {
                dismissSlashPanel()
                slashFeedbackMessage = nil
                session = opened
                viewModel.showChat(for: opened)
            }
        } catch {
            await MainActor.run {
                slashFeedbackMessage = error.localizedDescription
            }
        }
    }

    private func resumeLocalThread(_ candidate: SessionState) async {
        await MainActor.run {
            isExecutingSlashAction = true
        }
        defer {
            Task { @MainActor in
                isExecutingSlashAction = false
            }
        }

        do {
            // Resume works on saved thread ids exposed by CodexSessionMonitor.
            // The view swaps its preferred session immediately so the notch can
            // rebind to the reopened thread without recreating the whole scene.
            let opened = try await sessionMonitor.openLocalThread(threadId: candidate.sessionId)
            await MainActor.run {
                dismissSlashPanel()
                slashFeedbackMessage = nil
                session = opened
                viewModel.showChat(for: opened)
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
