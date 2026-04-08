//
//  SessionStore+History.swift
//  CodexIsland
//
//  Transcript-driven chat history synchronization and reconciliation.
//

import Foundation
import os.log

extension SessionStore {
    func processFileUpdate(_ payload: FileUpdatePayload) async {
        guard var session = sessions[payload.sessionId] else { return }
        let filteredPendingResult = filteredPendingInteractions(
            payload.pendingInteractions,
            transcriptPhase: payload.transcriptPhase,
            session: &session
        )

        let conversationInfo = await SessionTranscriptParser.shared.parse(session: session)
        let runtimeInfo = await SessionTranscriptParser.shared.runtimeInfo(session: session)
        session.conversationInfo = conversationInfo
        session.runtimeInfo = runtimeInfo
        session.pendingInteractions = filteredPendingResult.pendingInteractions
        if session.provider == .codex,
           let transcriptPhase = filteredPendingResult.transcriptPhase,
           session.phase.canTransition(to: transcriptPhase) {
            session.phase = transcriptPhase
        }

        if session.needsClearReconciliation {
            reconcileClearedHistory(payload.messages, session: &session)
        }

        applyMessages(
            payload.messages,
            isIncremental: payload.isIncremental,
            completedTools: payload.completedToolIds,
            toolResults: payload.toolResults,
            structuredResults: payload.structuredResults,
            session: &session
        )

        session.toolTracker.lastSyncTime = Date()

        await populateSubagentToolsFromAgentFiles(
            session: &session,
            cwd: payload.cwd,
            structuredResults: payload.structuredResults
        )

        sessions[payload.sessionId] = session

        await emitToolCompletionEvents(
            sessionId: payload.sessionId,
            session: session,
            completedToolIds: payload.completedToolIds,
            toolResults: payload.toolResults,
            structuredResults: payload.structuredResults
        )
    }

    func populateSubagentToolsFromAgentFiles(
        session: inout SessionState,
        cwd: String,
        structuredResults: [String: ToolResultData]
    ) async {
        for index in 0 ..< session.chatItems.count {
            guard case .toolCall(var tool) = session.chatItems[index].type,
                  tool.name == "Task",
                  let structuredResult = structuredResults[session.chatItems[index].id],
                  case .task(let taskResult) = structuredResult,
                  !taskResult.agentId.isEmpty else { continue }

            let taskToolId = session.chatItems[index].id

            if let description = session.subagentState.activeTasks[taskToolId]?.description {
                session.subagentState.agentDescriptions[taskResult.agentId] = description
            } else if let description = tool.input["description"] {
                session.subagentState.agentDescriptions[taskResult.agentId] = description
            }

            let subagentToolInfos = await ConversationParser.shared.parseSubagentTools(agentId: taskResult.agentId, cwd: cwd)
            guard !subagentToolInfos.isEmpty else { continue }

            tool.subagentTools = subagentToolInfos.map { info in
                SubagentToolCall(
                    id: info.id,
                    name: info.name,
                    input: info.input,
                    status: info.isCompleted ? .success : .running,
                    timestamp: parseTimestamp(info.timestamp) ?? Date()
                )
            }

            session.chatItems[index] = ChatHistoryItem(
                id: taskToolId,
                type: .toolCall(tool),
                timestamp: session.chatItems[index].timestamp
            )

            Self.logger.debug("Populated \(subagentToolInfos.count) subagent tools for Task \(taskToolId.prefix(12), privacy: .public) from agent \(taskResult.agentId.prefix(8), privacy: .public)")
        }
    }

    func emitToolCompletionEvents(
        sessionId: String,
        session: SessionState,
        completedToolIds: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData]
    ) async {
        for item in session.chatItems {
            guard case .toolCall(let tool) = item.type,
                  tool.status == .running || tool.status == .waitingForApproval,
                  completedToolIds.contains(item.id) else {
                continue
            }

            let result = ToolCompletionResult.from(
                parserResult: toolResults[item.id],
                structuredResult: structuredResults[item.id]
            )
            await process(.toolCompleted(sessionId: sessionId, toolUseId: item.id, result: result))
        }
    }

    func createChatItem(
        from block: MessageBlock,
        message: ChatMessage,
        blockIndex: Int,
        existingIds: Set<String>,
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        toolTracker: inout ToolTracker
    ) -> ChatHistoryItem? {
        switch block {
        case .text(let text):
            let itemId = "\(message.id)-text-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: message.role == .user ? .user(text) : .assistant(text), timestamp: message.timestamp)
        case .image(let attachment):
            let itemId = "\(message.id)-image-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            let type: ChatHistoryItemType = message.role == .user ? .userImage(attachment) : .assistantImage(attachment)
            return ChatHistoryItem(id: itemId, type: type, timestamp: message.timestamp)
        case .toolUse(let tool):
            guard toolTracker.markSeen(tool.id) else { return nil }
            let resultText = completedToolResultText(tool.id, completedTools: completedTools, toolResults: toolResults)
            return ChatHistoryItem(
                id: tool.id,
                type: .toolCall(ToolCallItem(
                    name: tool.name,
                    input: tool.input,
                    status: completedTools.contains(tool.id) ? .success : .running,
                    result: resultText,
                    structuredResult: structuredResults[tool.id],
                    subagentTools: []
                )),
                timestamp: message.timestamp
            )
        case .thinking(let text):
            let itemId = "\(message.id)-thinking-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .thinking(text), timestamp: message.timestamp)
        case .interrupted:
            let itemId = "\(message.id)-interrupted-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .interrupted, timestamp: message.timestamp)
        }
    }

    func processInterrupt(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }
        session.subagentState = SubagentState()
        ToolEventProcessor.markRunningToolsInterrupted(session: &session)
        if session.phase.canTransition(to: .idle) {
            session.phase = .idle
        }
        sessions[sessionId] = session
    }

    func processClearDetected(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }
        Self.logger.info("Processing /clear for session \(sessionId.prefix(8), privacy: .public)")
        session.needsClearReconciliation = true
        session.pendingInteractions.removeAll()
        sessions[sessionId] = session
        Self.logger.info("/clear processed for session \(sessionId.prefix(8), privacy: .public) - marked for reconciliation")
    }

    func processCodexProcessExited(sessionId: String) async {
        guard let session = sessions[sessionId], session.provider == .codex else { return }
        removeSession(sessionId: sessionId)
    }

    func processSessionEnd(sessionId: String) async {
        removeSession(sessionId: sessionId)
    }

    func loadHistoryFromFile(sessionId: String, cwd: String) async {
        guard let session = sessions[sessionId] else { return }
        let messages = await SessionTranscriptParser.shared.parseFullConversation(session: session)
        let completedTools = await SessionTranscriptParser.shared.completedToolIds(session: session)
        let toolResults = await SessionTranscriptParser.shared.toolResults(session: session)
        let structuredResults = await SessionTranscriptParser.shared.structuredResults(session: session)
        let pendingInteractions = await SessionTranscriptParser.shared.pendingInteractions(session: session)
        let transcriptPhase = await SessionTranscriptParser.shared.transcriptPhase(session: session)
        let conversationInfo = await SessionTranscriptParser.shared.parse(session: session)
        let runtimeInfo = await SessionTranscriptParser.shared.runtimeInfo(session: session)

        await process(.historyLoaded(
            sessionId: sessionId,
            messages: messages,
            completedTools: completedTools,
            toolResults: toolResults,
            structuredResults: structuredResults,
            pendingInteractions: pendingInteractions,
            transcriptPhase: transcriptPhase,
            conversationInfo: conversationInfo,
            runtimeInfo: runtimeInfo
        ))
    }

    func processHistoryLoaded(
        sessionId: String,
        messages: [ChatMessage],
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        pendingInteractions: [PendingInteraction],
        transcriptPhase: SessionPhase?,
        conversationInfo: ConversationInfo,
        runtimeInfo: SessionRuntimeInfo
    ) async {
        guard var session = sessions[sessionId] else { return }
        let filteredPendingResult = filteredPendingInteractions(
            pendingInteractions,
            transcriptPhase: transcriptPhase,
            session: &session
        )
        session.conversationInfo = conversationInfo
        session.runtimeInfo = runtimeInfo
        session.pendingInteractions = filteredPendingResult.pendingInteractions
        if session.provider == .codex,
           let transcriptPhase = filteredPendingResult.transcriptPhase,
           session.phase.canTransition(to: transcriptPhase) {
            session.phase = transcriptPhase
        }

        let existingIds = Set(session.chatItems.map { $0.id })
        for message in messages {
            for (blockIndex, block) in message.content.enumerated() {
                if let item = createChatItem(
                    from: block,
                    message: message,
                    blockIndex: blockIndex,
                    existingIds: existingIds,
                    completedTools: completedTools,
                    toolResults: toolResults,
                    structuredResults: structuredResults,
                    toolTracker: &session.toolTracker
                ) {
                    session.chatItems.append(item)
                }
            }
        }
        session.chatItems.sort { $0.timestamp < $1.timestamp }
        sessions[sessionId] = session
    }

    private func filteredPendingInteractions(
        _ pendingInteractions: [PendingInteraction],
        transcriptPhase: SessionPhase?,
        session: inout SessionState
    ) -> (pendingInteractions: [PendingInteraction], transcriptPhase: SessionPhase?) {
        guard session.provider == .codex,
              !session.suppressedPendingInteractionIDs.isEmpty else {
            return (pendingInteractions, transcriptPhase)
        }

        let filteredInteractions = pendingInteractions.filter { interaction in
            !session.suppressedPendingInteractionIDs.contains(interaction.id)
        }
        let removedSuppressedInteraction = filteredInteractions.count != pendingInteractions.count

        if transcriptPhase == .processing {
            session.suppressedPendingInteractionIDs.removeAll()
        }

        if removedSuppressedInteraction {
            return (filteredInteractions, .processing)
        }

        return (filteredInteractions, transcriptPhase)
    }

    private func reconcileClearedHistory(_ messages: [ChatMessage], session: inout SessionState) {
        var validIds = Set<String>()
        for message in messages {
            for (blockIndex, block) in message.content.enumerated() {
                switch block {
                case .toolUse(let tool):
                    validIds.insert(tool.id)
                case .text, .image, .thinking, .interrupted:
                    validIds.insert("\(message.id)-\(block.typePrefix)-\(blockIndex)")
                }
            }
        }

        let cutoffTime = Date().addingTimeInterval(-2)
        let previousCount = session.chatItems.count
        session.chatItems = session.chatItems.filter { item in
            validIds.contains(item.id) || item.timestamp > cutoffTime
        }
        session.toolTracker = ToolTracker()
        session.subagentState = SubagentState()
        session.needsClearReconciliation = false
        let keptCount = session.chatItems.count
        Self.logger.debug("Clear reconciliation: kept \(keptCount) of \(previousCount) items")
    }

    private func applyMessages(
        _ messages: [ChatMessage],
        isIncremental: Bool,
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        session: inout SessionState
    ) {
        let existingIds = Set(session.chatItems.map { $0.id })

        for message in messages {
            for (blockIndex, block) in message.content.enumerated() {
                if case .toolUse(let tool) = block,
                   mergeExistingToolItem(tool, timestamp: message.timestamp, session: &session) {
                    continue
                }

                if let item = createChatItem(
                    from: block,
                    message: message,
                    blockIndex: blockIndex,
                    existingIds: existingIds,
                    completedTools: completedTools,
                    toolResults: toolResults,
                    structuredResults: structuredResults,
                    toolTracker: &session.toolTracker
                ) {
                    session.chatItems.append(item)
                }
            }
        }

        if !isIncremental {
            session.chatItems.sort { $0.timestamp < $1.timestamp }
        }
    }

    private func mergeExistingToolItem(_ tool: ToolUseBlock, timestamp: Date, session: inout SessionState) -> Bool {
        guard let index = session.chatItems.firstIndex(where: { $0.id == tool.id }),
              case .toolCall(let existingTool) = session.chatItems[index].type else {
            return false
        }

        session.chatItems[index] = ChatHistoryItem(
            id: tool.id,
            type: .toolCall(ToolCallItem(
                name: tool.name,
                input: tool.input,
                status: existingTool.status,
                result: existingTool.result,
                structuredResult: existingTool.structuredResult,
                subagentTools: existingTool.subagentTools
            )),
            timestamp: timestamp
        )
        return true
    }

    private func completedToolResultText(
        _ toolId: String,
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult]
    ) -> String? {
        guard completedTools.contains(toolId),
              let parserResult = toolResults[toolId] else {
            return nil
        }
        if let stdout = parserResult.stdout, !stdout.isEmpty {
            return stdout
        }
        if let stderr = parserResult.stderr, !stderr.isEmpty {
            return stderr
        }
        return parserResult.content
    }
}
