//
//  CodexConversationParser+History.swift
//  CodexIsland
//
//  History item construction and conversation summary helpers.
//

import Foundation

extension CodexConversationParser {
    func buildHistoryItems(
        messages: [ChatMessage],
        completedToolIds: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData]
    ) -> [ChatHistoryItem] {
        var items: [ChatHistoryItem] = []

        for message in messages {
            for (blockIndex, block) in message.content.enumerated() {
                switch block {
                case .text(let text):
                    let itemId = "\(message.id)-text-\(blockIndex)"
                    let itemType: ChatHistoryItemType = message.role == .user ? .user(text) : .assistant(text)
                    items.append(ChatHistoryItem(id: itemId, type: itemType, timestamp: message.timestamp))
                case .image(let attachment):
                    let itemId = "\(message.id)-image-\(blockIndex)"
                    let itemType: ChatHistoryItemType = message.role == .user ? .userImage(attachment) : .assistantImage(attachment)
                    items.append(ChatHistoryItem(id: itemId, type: itemType, timestamp: message.timestamp))
                case .thinking(let text):
                    let itemId = "\(message.id)-thinking-\(blockIndex)"
                    items.append(ChatHistoryItem(id: itemId, type: .thinking(text), timestamp: message.timestamp))
                case .interrupted:
                    let itemId = "\(message.id)-interrupted-\(blockIndex)"
                    items.append(ChatHistoryItem(id: itemId, type: .interrupted, timestamp: message.timestamp))
                case .toolUse(let tool):
                    let isCompleted = completedToolIds.contains(tool.id)
                    let resultText = completedToolResultText(toolId: tool.id, completedToolIds: completedToolIds, toolResults: toolResults)
                    items.append(ChatHistoryItem(
                        id: tool.id,
                        type: .toolCall(ToolCallItem(
                            name: tool.name,
                            input: tool.input,
                            status: isCompleted ? .success : .running,
                            result: resultText,
                            structuredResult: structuredResults[tool.id],
                            subagentTools: []
                        )),
                        timestamp: message.timestamp
                    ))
                }
            }
        }

        return items.sorted { $0.timestamp < $1.timestamp }
    }

    func buildConversationInfo(
        messages: [ChatMessage],
        pendingInteractions: [PendingInteraction]
    ) -> ConversationInfo {
        let firstUser = messages.first(where: { $0.role == .user })?.textContent
        let lastUser = messages.last(where: { $0.role == .user })
        let lastTool = messages
            .flatMap(\.content)
            .reversed()
            .compactMap { block -> ToolUseBlock? in
                if case .toolUse(let tool) = block { return tool }
                return nil
            }
            .first
        let lastAssistantText = messages
            .reversed()
            .compactMap { message -> String? in
                guard message.role == .assistant else { return nil }
                return message.content.compactMap { block in
                    switch block {
                    case .text(let text), .thinking(let text):
                        return text
                    case .image, .toolUse, .interrupted:
                        return nil
                    }
                }.joined(separator: "\n")
            }
            .first

        let (lastMessage, lastRole, lastToolName): (String?, String?, String?)
        if let latestPending = pendingInteractions.last {
            lastMessage = latestPending.summaryText
            lastRole = "assistant"
            lastToolName = latestPending.isApproval ? latestPending.title : nil
        } else if let lastTool {
            lastMessage = truncate(lastTool.preview)
            lastRole = "tool"
            lastToolName = lastTool.name
        } else {
            lastMessage = truncate(lastAssistantText)
            lastRole = lastAssistantText == nil ? nil : "assistant"
            lastToolName = nil
        }

        return ConversationInfo(
            summary: truncate(firstUser, maxLength: 60),
            lastMessage: lastMessage,
            lastMessageRole: lastRole,
            lastToolName: lastToolName,
            firstUserMessage: truncate(firstUser, maxLength: 50),
            lastUserMessageDate: lastUser?.timestamp
        )
    }

    private func completedToolResultText(
        toolId: String,
        completedToolIds: Set<String>,
        toolResults: [String: ConversationParser.ToolResult]
    ) -> String? {
        guard completedToolIds.contains(toolId),
              let parserResult = toolResults[toolId] else {
            return nil
        }

        if let stdout = parserResult.stdout, !stdout.isEmpty {
            return stdout
        }
        if let stderr = parserResult.stderr, !stderr.isEmpty {
            return stderr
        }
        if let content = parserResult.content, !content.isEmpty {
            return content
        }
        return nil
    }
}
