//
//  ChatView+Components.swift
//  CodexIsland
//
//  Shared local chat message and interaction components
//

import Combine
import AppKit
import SwiftUI

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
        case .userImage(let attachment):
            UserImageMessageView(attachment: attachment)
        case .assistantImage(let attachment):
            AssistantImageMessageView(attachment: attachment)
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
            Circle()
                .fill(Color.white.opacity(0.6))
                .frame(width: 6, height: 6)
                .padding(.top, 5)

            MarkdownText(text, color: .white.opacity(0.9), fontSize: 13)

            Spacer(minLength: 60)
        }
    }
}

struct UserImageMessageView: View {
    let attachment: ChatImageAttachment

    var body: some View {
        HStack {
            Spacer(minLength: 60)

            ChatAttachmentImageView(attachment: attachment)
        }
    }
}

struct AssistantImageMessageView: View {
    let attachment: ChatImageAttachment

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(Color.white.opacity(0.6))
                .frame(width: 6, height: 6)
                .padding(.top, 5)

            ChatAttachmentImageView(attachment: attachment)

            Spacer(minLength: 60)
        }
    }
}

struct ChatAttachmentImageView: View {
    let attachment: ChatImageAttachment

    private let maxWidth: CGFloat = 220
    private let maxHeight: CGFloat = 160

    var body: some View {
        Group {
            switch attachment.source {
            case .remoteURL(let value):
                if let url = URL(string: value) {
                    AsyncImage(url: url) { phase in
                        imageContent(for: phase.image)
                    }
                } else {
                    placeholder
                }
            case .localPath(let path):
                imageContent(for: NSImage(contentsOfFile: (path as NSString).expandingTildeInPath).map(Image.init(nsImage:)))
            case .dataURL(let value):
                imageContent(for: decodeDataURL(value).map(Image.init(nsImage:)))
            }
        }
        .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: .leading)
        .accessibilityLabel(attachment.accessibilityLabel)
    }

    @ViewBuilder
    private func imageContent(for image: Image?) -> some View {
        if let image {
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .frame(width: 160, height: 110)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                    Text("Image unavailable")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
    }

    private func decodeDataURL(_ value: String) -> NSImage? {
        guard let commaIndex = value.firstIndex(of: ",") else { return nil }
        let payload = String(value[value.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) else {
            return nil
        }
        return NSImage(data: data)
    }
}

// MARK: - Processing Indicator

struct ProcessingIndicatorView: View {
    private let baseTexts = ["Processing", "Working"]
    private let color = TerminalColors.prompt
    private let baseText: String

    @State private var dotCount: Int = 1
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    init(turnId: String = "") {
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
                    .id(tool.status)
                    .onAppear {
                        if tool.status == .running || tool.status == .waitingForApproval {
                            startPulsing()
                        }
                    }

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

                if canExpand && tool.status != .running && tool.status != .waitingForApproval {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.3))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
                }
            }

            if tool.name == "Task" && !tool.subagentTools.isEmpty {
                SubagentToolsList(tools: tool.subagentTools)
                    .padding(.leading, 12)
                    .padding(.top, 2)
            }

            if showContent && tool.status != .running && tool.name != "Task" && (hasResult || tool.name == "Edit") {
                ToolResultContent(tool: tool)
                    .padding(.leading, 12)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

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
        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
            pulseOpacity = 0.15
        }
    }
}

// MARK: - Subagent Views

struct SubagentToolsList: View {
    let tools: [SubagentToolCall]

    private var hiddenCount: Int {
        max(0, tools.count - 2)
    }

    private var recentTools: [SubagentToolCall] {
        Array(tools.suffix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if hiddenCount > 0 {
                Text("+\(hiddenCount) more tool uses")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }

            ForEach(recentTools) { tool in
                SubagentToolRow(tool: tool)
            }
        }
    }
}

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

    private var statusText: String {
        if tool.status == .interrupted {
            return "Interrupted"
        }
        return ToolStatusDisplay.running(for: tool.name, input: tool.input).text
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor.opacity(tool.status == .running ? dotOpacity : 0.6))
                .frame(width: 4, height: 4)
                .id(tool.status)
                .onAppear {
                    if tool.status == .running {
                        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                            dotOpacity = 0.2
                        }
                    }
                }

            Text(tool.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            Text(statusText)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

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
                    choiceQuestionContent(question: question, request: request, isReadOnly: isReadOnly)
                } else {
                    textQuestionContent(question: question, request: request, isReadOnly: isReadOnly)
                }

                if isSubmitting {
                    Text("Sending answer...")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
        }
    }

    private func choiceQuestionContent(
        question: PendingInteractionQuestion,
        request: PendingUserInputInteraction,
        isReadOnly: Bool
    ) -> some View {
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
                otherAnswerField(question: question, request: request, isReadOnly: isReadOnly)
            }

            if isReadOnly {
                terminalFallbackHint
                terminalShortcutButton(alignment: .leading)
            }
        }
    }

    private func otherAnswerField(
        question: PendingInteractionQuestion,
        request: PendingUserInputInteraction,
        isReadOnly: Bool
    ) -> some View {
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
                    submitTextAnswer(for: question, request: request, isReadOnly: isReadOnly)
                }

            Button {
                submitTextAnswer(for: question, request: request, isReadOnly: isReadOnly)
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

    private func textQuestionContent(
        question: PendingInteractionQuestion,
        request: PendingUserInputInteraction,
        isReadOnly: Bool
    ) -> some View {
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
                        submitTextAnswer(for: question, request: request, isReadOnly: isReadOnly)
                    }

                Button {
                    submitTextAnswer(for: question, request: request, isReadOnly: isReadOnly)
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

    private func submitTextAnswer(
        for question: PendingInteractionQuestion,
        request: PendingUserInputInteraction,
        isReadOnly: Bool
    ) {
        guard !isReadOnly else { return }
        guard !textAnswer.isEmpty else { return }
        selectedAnswers[question.id] = textAnswer
        Task {
            await advanceOrSubmit(request: request)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(MCPToolFormatter.formatToolName(tool))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(TerminalColors.amber)
                if let toolInput {
                    Text(toolInput)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .opacity(showContent ? 1 : 0)
            .offset(x: showContent ? 0 : -10)

            Spacer()

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
        .frame(minHeight: 44)
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
