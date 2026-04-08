//
//  RemoteChatView+Components.swift
//  CodexIsland
//
//  Split-out presentation components for the remote chat container.
//

import SwiftUI

struct RemoteChatHeaderView: View {
    let thread: RemoteThreadState
    let isPlanModeActive: Bool
    @Binding var isHeaderHovered: Bool
    let onExit: () -> Void
    let onInterrupt: () -> Void

    private var shouldShowDebugConversationID: Bool {
        AppSettings.remoteDiagnosticsLoggingEnabled
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onExit) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(isHeaderHovered ? 1.0 : 0.6))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(thread.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
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

                Text(thread.sourceDetail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.35))
                    .lineLimit(1)

                SessionStatusStrip(
                    model: thread.currentModel,
                    reasoningEffort: thread.currentReasoningEffort?.rawValue,
                    serviceTier: thread.turnContext.serviceTier?.rawValue,
                    contextRemainingPercent: thread.contextRemainingPercent
                )

                if shouldShowDebugConversationID {
                    DebugConversationIDView(
                        label: "Thread ID",
                        value: thread.threadId
                    )
                }
            }

            Spacer()

            if thread.canInterrupt {
                Button(action: onInterrupt) {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.2))
        .onHover { isHeaderHovered = $0 }
    }
}

struct RemoteChatEmptyStateView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.2))
            Text("No thread history yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RemoteChatLoadingStateView: View {
    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.4)))
                .scaleEffect(0.8)
            Text("Opening remote session...")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RemoteChatMessageListView: View {
    let history: [ChatHistoryItem]
    let logicalSessionId: String
    @Binding var shouldScrollToBottom: Bool
    let isAutoscrollPaused: Bool
    let newMessageCount: Int
    let onResumeAutoscroll: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 16) {
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")

                    ForEach(history.reversed()) { item in
                        MessageItemView(item: item, sessionId: logicalSessionId)
                            .padding(.horizontal, 16)
                            .scaleEffect(x: 1, y: -1)
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 20)
            }
            .scaleEffect(x: 1, y: -1)
            .onChange(of: shouldScrollToBottom) { _, shouldScroll in
                guard shouldScroll else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                shouldScrollToBottom = false
                onResumeAutoscroll()
            }
            .overlay(alignment: .bottom) {
                if isAutoscrollPaused && newMessageCount > 0 {
                    NewMessagesIndicator(count: newMessageCount) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        onResumeAutoscroll()
                    }
                    .padding(.bottom, 16)
                }
            }
        }
    }
}

struct RemoteChatComposerView: View {
    let thread: RemoteThreadState
    let isPlanModeActive: Bool
    @Binding var inputText: String
    let isInputFocused: FocusState<Bool>.Binding
    @Binding var activeSlashPanel: RemoteSlashPanel?
    @Binding var slashFeedbackMessage: String?
    let isSlashPanelLoading: Bool
    let isExecutingSlashAction: Bool
    let availableModels: [RemoteAppServerModel]
    @Binding var selectedModelForEffort: RemoteAppServerModel?
    let resumeCandidates: [RemoteThreadState]
    let matchingSlashCommands: [RemoteSlashCommand]
    let inputPrompt: String
    let onSubmit: () -> Void
    let onHandleSlashCommand: (RemoteSlashCommand, String?) -> Void
    let onDismissSlashPanel: () -> Void
    let onApplyModelSelection: (RemoteAppServerModel, RemoteAppServerReasoningEffort) async -> Void
    let onApplyPermissionPreset: (RemoteApprovalPreset) async -> Void
    let onResumeRemoteThread: (RemoteThreadState) async -> Void

    private let fadeColor = Color.black

    var body: some View {
        VStack(spacing: 8) {
            if isPlanModeActive {
                planModeBanner
            }

            if let connectionMessage = thread.connectionFeedbackMessage {
                slashFeedbackBanner(message: connectionMessage)
            }

            if let activeSlashPanel {
                RemoteChatSlashPanelView(
                    panel: activeSlashPanel,
                    thread: thread,
                    isLoading: isSlashPanelLoading,
                    isExecutingSlashAction: isExecutingSlashAction,
                    availableModels: availableModels,
                    selectedModelForEffort: $selectedModelForEffort,
                    resumeCandidates: resumeCandidates,
                    onDismiss: onDismissSlashPanel,
                    onApplyModelSelection: onApplyModelSelection,
                    onApplyPermissionPreset: onApplyPermissionPreset,
                    onResumeRemoteThread: onResumeRemoteThread
                )
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

    private var slashSuggestionsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remote commands")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            ForEach(matchingSlashCommands) { command in
                Button {
                    onHandleSlashCommand(command, nil)
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

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField(inputPrompt, text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(thread.canSendMessage ? .white : .white.opacity(0.4))
                .focused(isInputFocused)
                .disabled(!thread.canSendMessage)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(thread.canSendMessage ? 0.08 : 0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                        )
                )
                .onSubmit(onSubmit)

            Button(action: onSubmit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(!thread.canSendMessage || inputText.isEmpty ? .white.opacity(0.2) : .white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .disabled(!thread.canSendMessage || inputText.isEmpty)
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
            .offset(y: -24)
            .allowsHitTesting(false)
        }
    }
}

private struct RemoteChatSlashPanelView: View {
    let panel: RemoteSlashPanel
    let thread: RemoteThreadState
    let isLoading: Bool
    let isExecutingSlashAction: Bool
    let availableModels: [RemoteAppServerModel]
    @Binding var selectedModelForEffort: RemoteAppServerModel?
    let resumeCandidates: [RemoteThreadState]
    let onDismiss: () -> Void
    let onApplyModelSelection: (RemoteAppServerModel, RemoteAppServerReasoningEffort) async -> Void
    let onApplyPermissionPreset: (RemoteApprovalPreset) async -> Void
    let onResumeRemoteThread: (RemoteThreadState) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.92))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading…")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.55))
                }
                .padding(.vertical, 8)
            } else {
                panelContent
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var panelContent: some View {
        switch panel {
        case .model:
            modelPanelContent
        case .permissions:
            permissionsPanelContent
        case .resume:
            resumePanelContent
        }
    }

    private var title: String {
        switch panel {
        case .model:
            return "/model"
        case .permissions:
            return "/permissions"
        case .resume:
            return "/resume"
        }
    }

    private var subtitle: String {
        switch panel {
        case .model:
            return "Choose what model and reasoning effort to use."
        case .permissions:
            return "Choose what Codex is allowed to do."
        case .resume:
            return "Resume a saved chat."
        }
    }

    private var modelPanelContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selectedModel = selectedModelForEffort {
                Text("Choose reasoning effort for \(selectedModel.displayName)")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))

                ForEach(selectedModel.supportedReasoningEfforts, id: \.reasoningEffort) { option in
                    RemoteChatSlashActionButton(
                        title: option.reasoningEffort.rawValue,
                        note: option.description,
                        isDisabled: isExecutingSlashAction
                    ) {
                        await onApplyModelSelection(selectedModel, option.reasoningEffort)
                    }
                }

                RemoteChatSlashActionButton(
                    title: "Use default",
                    note: selectedModel.defaultReasoningEffort.rawValue,
                    isDisabled: isExecutingSlashAction
                ) {
                    await onApplyModelSelection(
                        selectedModel,
                        selectedModel.defaultReasoningEffort
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
                    let isCurrent = model.model == (thread.currentModel ?? thread.turnContext.model)
                    Button {
                        if model.supportedReasoningEfforts.count <= 1 {
                            Task {
                                await onApplyModelSelection(model, model.defaultReasoningEffort)
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
            ForEach(RemoteApprovalPreset.builtIn) { preset in
                let isCurrent = thread.turnContext.approvalPolicy == preset.approvalPolicy &&
                    thread.turnContext.sandboxPolicy == preset.sandboxPolicy
                Button {
                    Task {
                        await onApplyPermissionPreset(preset)
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
                Text("No other remote threads available on this host")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
            } else {
                ForEach(resumeCandidates) { candidate in
                    Button {
                        Task {
                            await onResumeRemoteThread(candidate)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(candidate.displayTitle)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.88))
                                    .lineLimit(1)
                                Spacer()
                                Text(candidate.updatedAt.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.35))
                            }
                            Text(candidate.sourceDetail)
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
}

private struct RemoteChatSlashActionButton: View {
    let title: String
    let note: String
    let isDisabled: Bool
    let action: () async -> Void

    var body: some View {
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
        .disabled(isDisabled)
    }
}
