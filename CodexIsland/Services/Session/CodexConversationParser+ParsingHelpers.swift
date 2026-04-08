//
//  CodexConversationParser+ParsingHelpers.swift
//  CodexIsland
//
//  Text, JSON, and interaction helper parsing for Codex transcripts.
//

import Foundation

extension CodexConversationParser {
    func parseMessageContent(_ content: [[String: Any]]?) -> (blocks: [MessageBlock], containsProposedPlan: Bool) {
        guard let content else { return ([], false) }
        var containsProposedPlan = false
        let blocks = content.compactMap { item -> MessageBlock? in
            guard let type = item["type"] as? String else { return nil }
            switch type {
            case "input_text", "output_text":
                guard let text = item["text"] as? String else { return nil }
                let normalized = normalizeMessageText(text)
                containsProposedPlan = containsProposedPlan || normalized.containsProposedPlan
                guard !normalized.text.isEmpty else { return nil }
                return .text(normalized.text)
            case "input_image", "output_image", "image":
                return parseImageAttachment(item).map(MessageBlock.image)
            case "local_image":
                return parseLocalImageAttachment(item).map(MessageBlock.image)
            default:
                return nil
            }
        }
        return (blocks, containsProposedPlan)
    }

    func normalizeMessageText(_ text: String) -> (text: String, containsProposedPlan: Bool) {
        let containsProposedPlan = text.contains("<proposed_plan>") || text.contains("</proposed_plan>")
        let strippedImageTags = stripImageTagMarkup(from: text)
        let normalized = strippedImageTags
            .replacingOccurrences(of: "<proposed_plan>", with: "")
            .replacingOccurrences(of: "</proposed_plan>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (normalized, containsProposedPlan)
    }

    func parseImageAttachment(_ item: [String: Any]) -> ChatImageAttachment? {
        let label = item["name"] as? String ?? item["alt"] as? String ?? item["label"] as? String
        if let imageURL = item["image_url"] as? String, !imageURL.isEmpty {
            let source: ChatImageAttachment.Source = imageURL.hasPrefix("data:image/")
                ? .dataURL(imageURL)
                : .remoteURL(imageURL)
            return ChatImageAttachment(source: source, label: label)
        }
        if let url = item["url"] as? String, !url.isEmpty {
            let source: ChatImageAttachment.Source = url.hasPrefix("data:image/")
                ? .dataURL(url)
                : .remoteURL(url)
            return ChatImageAttachment(source: source, label: label)
        }
        return nil
    }

    func parseLocalImageAttachment(_ item: [String: Any]) -> ChatImageAttachment? {
        let label = item["name"] as? String ?? item["alt"] as? String ?? item["label"] as? String
        if let path = item["path"] as? String, !path.isEmpty {
            return ChatImageAttachment(source: .localPath(path), label: label)
        }
        return parseImageAttachment(item)
    }

    func stripImageTagMarkup(from text: String) -> String {
        let patterns = [
            #"<image\b[^>]*>.*?</image>"#,
            #"</?image\b[^>]*>"#,
            #"\s*\[Image #\d+\]\s*"#
        ]

        var sanitized = text
        for pattern in patterns {
            sanitized = replacingMatches(in: sanitized, pattern: pattern, template: "")
        }

        sanitized = replacingMatches(in: sanitized, pattern: #"\n{3,}"#, template: "\n\n")
        sanitized = replacingMatches(in: sanitized, pattern: #"[ \t]{2,}"#, template: " ")
        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func replacingMatches(in text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return text
        }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    func makeProposedPlanFollowupInteraction(lineIndex: Int) -> PendingUserInputInteraction {
        PendingUserInputInteraction(
            id: "plan-followup-\(lineIndex)",
            title: "Codex needs your input",
            questions: [
                PendingInteractionQuestion(
                    id: "plan_mode_followup",
                    header: "Next step",
                    question: "Implement this plan?",
                    options: [
                        PendingInteractionOption(label: "Yes, implement this plan", description: "Switch to Default and start coding."),
                        PendingInteractionOption(label: "No, stay in Plan mode", description: "Continue planning with the model.")
                    ],
                    isOther: false,
                    isSecret: false
                )
            ],
            transport: .codexLocal(callId: nil, turnId: nil)
        )
    }

    func isCodexInjectedText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("# AGENTS.md instructions for ") ||
            trimmed.hasPrefix("<environment_context>") ||
            trimmed.hasPrefix("<permissions instructions>") ||
            trimmed.hasPrefix("<collaboration_mode>") ||
            trimmed.hasPrefix("<turn_aborted>") ||
            trimmed.hasPrefix("<skills_instructions>") ||
            trimmed.hasPrefix("<plugins_instructions>") ||
            trimmed.hasPrefix("<apps_instructions>") ||
            trimmed.hasPrefix("<user_instructions>")
    }

    func parseReasoningText(_ payload: [String: Any]) -> String {
        let summaryText = (payload["summary"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        let contentText = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        return (summaryText + contentText).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parseLocalShellCommand(_ payload: [String: Any]) -> String {
        guard let action = payload["action"] as? [String: Any],
              let command = action["command"] as? [String] else {
            return ""
        }
        return command.joined(separator: " ")
    }

    func parsePendingInteraction(callId: String, toolName: String, arguments: String?) -> PendingInteraction? {
        switch toolName {
        case "request_user_input":
            guard let json = parseJSONArguments(arguments),
                  let questions = parseInteractionQuestions(json["questions"] as? [[String: Any]]),
                  !questions.isEmpty else {
                return nil
            }
            return .userInput(PendingUserInputInteraction(
                id: callId,
                title: "Codex needs your input",
                questions: questions,
                transport: .codexLocal(callId: callId, turnId: nil)
            ))
        case "request_permissions":
            guard let json = parseJSONArguments(arguments) else { return nil }
            return .approval(PendingApprovalInteraction(
                id: callId,
                title: "Permissions Request",
                kind: .permissions,
                detail: json["reason"] as? String,
                requestedPermissions: parsePermissionProfile(json["permissions"] as? [String: Any]),
                availableActions: [.allow, .allowForSession, .deny],
                transport: .codexLocal(callId: callId, turnId: nil)
            ))
        default:
            return nil
        }
    }

    func parseRequestPermissionsEvent(payload: [String: Any]) -> PendingInteraction? {
        guard let callId = payload["call_id"] as? String else { return nil }
        return .approval(PendingApprovalInteraction(
            id: callId,
            title: "Permissions Request",
            kind: .permissions,
            detail: payload["reason"] as? String,
            requestedPermissions: parsePermissionProfile(payload["permissions"] as? [String: Any]),
            availableActions: [.allow, .allowForSession, .deny],
            transport: .codexLocal(callId: callId, turnId: payload["turn_id"] as? String)
        ))
    }

    func parseRequestUserInputEvent(payload: [String: Any]) -> PendingInteraction? {
        let callId = payload["call_id"] as? String ??
            payload["item_id"] as? String ??
            payload["itemId"] as? String ??
            payload["request_id"] as? String ??
            payload["requestId"] as? String
        guard let callId,
              let questions = parseInteractionQuestions(payload["questions"] as? [[String: Any]]),
              !questions.isEmpty else {
            return nil
        }

        let turnId = payload["turn_id"] as? String ?? payload["turnId"] as? String
        return .userInput(PendingUserInputInteraction(
            id: callId,
            title: "Codex needs your input",
            questions: questions,
            transport: .codexLocal(callId: callId, turnId: turnId)
        ))
    }

    func parseExecApprovalEvent(payload: [String: Any]) -> PendingInteraction? {
        let callId = payload["approval_id"] as? String ?? payload["call_id"] as? String
        guard let callId else { return nil }
        let detail = [parseExecApprovalCommand(payload["command"]), payload["reason"] as? String]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n")
        return .approval(PendingApprovalInteraction(
            id: callId,
            title: "Command Execution",
            kind: .commandExecution,
            detail: detail.isEmpty ? nil : detail,
            requestedPermissions: parsePermissionProfile(payload["additional_permissions"] as? [String: Any]),
            availableActions: parseApprovalActions(payload["available_decisions"]) ?? [.allow, .cancel],
            transport: .codexLocal(callId: payload["call_id"] as? String, turnId: payload["turn_id"] as? String)
        ))
    }

    func parseExecApprovalCommand(_ value: Any?) -> String? {
        if let command = value as? String {
            return command
        }
        if let command = value as? [String] {
            return command.joined(separator: " ")
        }
        if let command = value as? [Any] {
            return command.compactMap { $0 as? String }.joined(separator: " ")
        }
        return nil
    }

    func parseApprovalActions(_ value: Any?) -> [PendingApprovalAction]? {
        guard let rawArray = value as? [Any] else { return nil }
        let actions = rawArray.compactMap { raw -> PendingApprovalAction? in
            guard let string = raw as? String else { return nil }
            switch string {
            case "approved", "accept":
                return .allow
            case "approved_for_session", "acceptForSession":
                return .allowForSession
            case "denied", "decline":
                return .deny
            case "abort", "cancel":
                return .cancel
            default:
                return nil
            }
        }
        return actions.isEmpty ? nil : actions
    }

    func parseInteractionQuestions(_ value: [[String: Any]]?) -> [PendingInteractionQuestion]? {
        guard let value else { return nil }
        let questions = value.compactMap { question -> PendingInteractionQuestion? in
            guard let id = question["id"] as? String,
                  let header = question["header"] as? String,
                  let prompt = question["question"] as? String else {
                return nil
            }

            let options = (question["options"] as? [[String: Any]] ?? []).compactMap { option -> PendingInteractionOption? in
                guard let label = option["label"] as? String else { return nil }
                return PendingInteractionOption(label: label, description: option["description"] as? String)
            }

            return PendingInteractionQuestion(
                id: id,
                header: header,
                question: prompt,
                options: options,
                isOther: question["isOther"] as? Bool ?? question["is_other"] as? Bool ?? false,
                isSecret: question["isSecret"] as? Bool ?? question["is_secret"] as? Bool ?? false
            )
        }
        return questions.isEmpty ? nil : questions
    }

    func parsePermissionProfile(_ value: [String: Any]?) -> InteractionPermissionProfile {
        guard let value else { return .none }
        let networkValue = value["network"] as? [String: Any]
        let fileSystemValue = value["fileSystem"] as? [String: Any] ?? value["file_system"] as? [String: Any]
        return InteractionPermissionProfile(
            networkEnabled: networkValue?["enabled"] as? Bool,
            readRoots: fileSystemValue?["read"] as? [String] ?? [],
            writeRoots: fileSystemValue?["write"] as? [String] ?? []
        )
    }

    func parseJSONArguments(_ arguments: String?) -> [String: Any]? {
        guard let arguments,
              let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    func parseJSONStringInput(_ arguments: String?) -> [String: String] {
        guard let json = parseJSONArguments(arguments) else { return [:] }
        return parseJSONObjectInput(json)
    }

    func parseJSONObjectInput(_ json: [String: Any]?) -> [String: String] {
        guard let json else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in json {
            if let stringValue = stringify(value) {
                result[key] = stringValue
            }
        }
        return result
    }

    func parseWebSearchInput(_ action: [String: Any]?) -> [String: String] {
        guard let action, let type = action["type"] as? String else { return [:] }
        switch type {
        case "search":
            if let query = action["query"] as? String {
                return ["query": query]
            }
            if let queries = action["queries"] as? [String] {
                return ["query": queries.joined(separator: ", ")]
            }
        case "open_page":
            if let url = action["url"] as? String {
                return ["url": url]
            }
        case "find_in_page":
            var result: [String: String] = [:]
            if let url = action["url"] as? String {
                result["url"] = url
            }
            if let pattern = action["pattern"] as? String {
                result["pattern"] = pattern
            }
            return result
        default:
            break
        }
        return [:]
    }

    func parseWebSearchResult(_ action: [String: Any]?) -> String? {
        guard let action else { return nil }
        return parseWebSearchInput(action)
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: "\n")
    }

    func parseToolSearchOutput(_ payload: [String: Any]) -> String {
        if let execution = payload["execution"] as? String, !execution.isEmpty {
            return execution
        }
        if let tools = payload["tools"] as? [Any] {
            return "Returned \(tools.count) tools"
        }
        return ""
    }

    func parseOutputText(_ output: Any?) -> String? {
        if let output = output as? String {
            return output
        }

        if let items = output as? [[String: Any]] {
            let texts = items.compactMap { item -> String? in
                if let text = item["text"] as? String {
                    return text
                }
                if let content = item["content"] as? String {
                    return content
                }
                return nil
            }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }

        if let output {
            return stringify(output)
        }

        return nil
    }

    func stringify(_ value: Any) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let array as [String]:
            return array.joined(separator: " ")
        case let array as [Any]:
            if JSONSerialization.isValidJSONObject(array),
               let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys]),
               let string = String(data: data, encoding: .utf8) {
                return string
            }
            return nil
        case let dictionary as [String: Any]:
            if JSONSerialization.isValidJSONObject(dictionary),
               let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
               let string = String(data: data, encoding: .utf8) {
                return string
            }
            return nil
        default:
            return nil
        }
    }

    func parseTimestamp(_ rawValue: String?) -> Date {
        guard let rawValue else { return Date() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: rawValue) ?? Date()
    }

    func truncate(_ text: String?, maxLength: Int = 80) -> String? {
        guard let text else { return nil }
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard cleaned.count > maxLength else { return cleaned }
        return String(cleaned.prefix(maxLength - 3)) + "..."
    }
}
