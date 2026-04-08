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
                let offset = TimeInterval(turnIndex * 100 + itemIndex)
                let timestamp = baseDate.addingTimeInterval(offset)
                items.append(contentsOf: chatHistoryItems(from: item, timestamp: timestamp))
            }
        }

        return items
    }

    static func chatHistoryItem(from item: RemoteAppServerThreadItem) -> ChatHistoryItem? {
        chatHistoryItems(from: item, timestamp: Date()).first
    }

    static func chatHistoryItems(from item: RemoteAppServerThreadItem, timestamp: Date = Date()) -> [ChatHistoryItem] {
        switch item {
        case .userMessage(let id, let content):
            return userHistoryItems(id: id, content: content, timestamp: timestamp)
        case .agentMessage(let id, let text):
            return [ChatHistoryItem(id: id, type: .assistant(text), timestamp: timestamp)]
        case .reasoning(let id, let summary, let content):
            let text = normalizedText(summary + content)
            guard let text else { return [] }
            return [ChatHistoryItem(id: id, type: .thinking(text), timestamp: timestamp)]
        case .plan(let id, let text):
            guard let text = normalizedText([text]) else { return [] }
            return [ChatHistoryItem(id: id, type: .thinking(text), timestamp: timestamp)]
        case .commandExecution(let id, let command, _, let status, let aggregatedOutput):
            return [ChatHistoryItem(
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
            )]
        case .fileChange(let id, let changes, let status):
            let pathSummary = changes.map(\.path).joined(separator: ", ")
            return [ChatHistoryItem(
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
            )]
        case .enteredReviewMode(let id, let review), .exitedReviewMode(let id, let review):
            return [ChatHistoryItem(id: id, type: .assistant(review), timestamp: timestamp)]
        case .contextCompaction(let id):
            return [ChatHistoryItem(
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
            )]
        case .unsupported:
            return []
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

    private static func normalizedText(_ lines: [String]) -> String? {
        let text = lines
            .joined(separator: "\n")
            .removingImageTagMarkup()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func userHistoryItems(
        id: String,
        content: [RemoteAppServerUserInput],
        timestamp: Date
    ) -> [ChatHistoryItem] {
        var items: [ChatHistoryItem] = []
        var textIndex = 0
        var imageIndex = 0
        var usedBaseID = false

        for input in content {
            switch input {
            case .text(let text):
                let normalized = normalizedText([text])
                guard let normalized else { continue }
                items.append(ChatHistoryItem(
                    id: nextUserItemID(baseID: id, suffix: "text-\(textIndex)", usedBaseID: &usedBaseID),
                    type: .user(normalized),
                    timestamp: timestamp
                ))
                textIndex += 1
            case .image(let url):
                guard !url.isEmpty else { continue }
                let source: ChatImageAttachment.Source = url.hasPrefix("data:image/")
                    ? .dataURL(url)
                    : .remoteURL(url)
                items.append(ChatHistoryItem(
                    id: nextUserItemID(baseID: id, suffix: "image-\(imageIndex)", usedBaseID: &usedBaseID),
                    type: .userImage(ChatImageAttachment(source: source, label: nil)),
                    timestamp: timestamp
                ))
                imageIndex += 1
            case .localImage(let path):
                guard !path.isEmpty else { continue }
                items.append(ChatHistoryItem(
                    id: nextUserItemID(baseID: id, suffix: "image-\(imageIndex)", usedBaseID: &usedBaseID),
                    type: .userImage(ChatImageAttachment(source: .localPath(path), label: nil)),
                    timestamp: timestamp
                ))
                imageIndex += 1
            case .skill, .mention, .unsupported:
                continue
            }
        }

        return items
    }

    private static func nextUserItemID(baseID: String, suffix: String, usedBaseID: inout Bool) -> String {
        if !usedBaseID {
            usedBaseID = true
            return baseID
        }
        return "\(baseID)-\(suffix)"
    }
}

private extension String {
    func removingImageTagMarkup() -> String {
        let patterns = [
            #"<image\b[^>]*>.*?</image>"#,
            #"</?image\b[^>]*>"#,
            #"\s*\[Image #\d+\]\s*"#
        ]

        var sanitized = self
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else {
                continue
            }
            let range = NSRange(sanitized.startIndex ..< sanitized.endIndex, in: sanitized)
            sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: range, withTemplate: "")
        }

        guard let blankLineRegex = try? NSRegularExpression(pattern: #"\n{3,}"#) else {
            return sanitized
        }
        let range = NSRange(sanitized.startIndex ..< sanitized.endIndex, in: sanitized)
        sanitized = blankLineRegex.stringByReplacingMatches(in: sanitized, options: [], range: range, withTemplate: "\n\n")
        guard let extraSpaceRegex = try? NSRegularExpression(pattern: #"[ \t]{2,}"#) else {
            return sanitized
        }
        let extraSpaceRange = NSRange(sanitized.startIndex ..< sanitized.endIndex, in: sanitized)
        return extraSpaceRegex.stringByReplacingMatches(in: sanitized, options: [], range: extraSpaceRange, withTemplate: " ")
    }
}
