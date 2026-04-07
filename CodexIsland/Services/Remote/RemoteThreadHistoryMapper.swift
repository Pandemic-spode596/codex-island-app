//
//  RemoteThreadHistoryMapper.swift
//  CodexIsland
//
//  Mapping helpers from remote app-server turns/items into UI-facing history models.
//

import Foundation

enum RemoteThreadHistoryMapper {
    static func historyItems(from turns: [RemoteAppServerTurn]) -> [ChatHistoryItem] {
        var items: [ChatHistoryItem] = []
        let baseDate = Date()

        for (turnIndex, turn) in turns.enumerated() {
            for (itemIndex, item) in turn.items.enumerated() {
                guard let chatItem = chatHistoryItem(from: item) else { continue }
                let offset = TimeInterval(turnIndex * 100 + itemIndex)
                items.append(ChatHistoryItem(
                    id: chatItem.id,
                    type: chatItem.type,
                    timestamp: baseDate.addingTimeInterval(offset)
                ))
            }
        }

        return items
    }

    static func chatHistoryItem(from item: RemoteAppServerThreadItem) -> ChatHistoryItem? {
        let timestamp = Date()
        switch item {
        case .userMessage(let id, let content):
            let text = content.compactMap(\.displayText).joined(separator: "\n")
            return ChatHistoryItem(id: id, type: .user(text), timestamp: timestamp)
        case .agentMessage(let id, let text):
            return ChatHistoryItem(id: id, type: .assistant(text), timestamp: timestamp)
        case .reasoning(let id, let summary, let content):
            let text = (summary + content).joined(separator: "\n")
            return ChatHistoryItem(id: id, type: .thinking(text), timestamp: timestamp)
        case .plan(let id, let text):
            return ChatHistoryItem(id: id, type: .thinking(text), timestamp: timestamp)
        case .commandExecution(let id, let command, _, let status, let aggregatedOutput):
            return ChatHistoryItem(
                id: id,
                type: .toolCall(ToolCallItem(
                    name: "Command",
                    input: ["command": command],
                    status: toolStatus(from: status),
                    result: aggregatedOutput,
                    structuredResult: nil,
                    subagentTools: []
                )),
                timestamp: timestamp
            )
        case .fileChange(let id, let changes, let status):
            let pathSummary = changes.map(\.path).joined(separator: ", ")
            return ChatHistoryItem(
                id: id,
                type: .toolCall(ToolCallItem(
                    name: "Edit",
                    input: ["path": pathSummary],
                    status: toolStatus(from: status),
                    result: changes.first?.diff,
                    structuredResult: nil,
                    subagentTools: []
                )),
                timestamp: timestamp
            )
        case .enteredReviewMode(let id, let review), .exitedReviewMode(let id, let review):
            return ChatHistoryItem(id: id, type: .assistant(review), timestamp: timestamp)
        case .contextCompaction(let id):
            return ChatHistoryItem(
                id: id,
                type: .toolCall(ToolCallItem(
                    name: "Compact",
                    input: [:],
                    status: .success,
                    result: nil,
                    structuredResult: nil,
                    subagentTools: []
                )),
                timestamp: timestamp
            )
        case .unsupported:
            return nil
        }
    }

    static func buildPlanSummary(explanation: String?, plan: [RemoteAppServerPlanStep]) -> String {
        let lines = plan.map { step in
            "- [\(step.status)] \(step.step)"
        }
        let parts = [explanation].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        } + lines
        return parts.joined(separator: "\n")
    }

    static func activeTurn(from turns: [RemoteAppServerTurn]) -> RemoteAppServerTurn? {
        turns.last(where: isActiveTurn)
    }

    private static func isActiveTurn(_ turn: RemoteAppServerTurn) -> Bool {
        if turn.status == .inProgress {
            return true
        }

        return turn.items.contains { item in
            switch item {
            case .commandExecution(_, _, _, let status, _):
                return status == .inProgress
            case .fileChange(_, _, let status):
                return status == .inProgress
            default:
                return false
            }
        }
    }

    private static func toolStatus(from status: RemoteAppServerCommandExecutionStatus) -> ToolStatus {
        switch status {
        case .inProgress:
            return .running
        case .completed:
            return .success
        case .failed, .declined:
            return .error
        }
    }

    private static func toolStatus(from status: RemoteAppServerPatchApplyStatus) -> ToolStatus {
        switch status {
        case .inProgress:
            return .running
        case .completed:
            return .success
        case .failed, .declined:
            return .error
        }
    }
}
