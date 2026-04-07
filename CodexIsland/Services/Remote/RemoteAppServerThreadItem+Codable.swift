//
//  RemoteAppServerThreadItem+Codable.swift
//  CodexIsland
//
//  Codable and decoding helpers for remote app-server thread items.
//

import Foundation

extension RemoteAppServerThreadItem {
    var id: String {
        switch self {
        case .userMessage(let id, _),
             .agentMessage(let id, _),
             .reasoning(let id, _, _),
             .plan(let id, _),
             .commandExecution(let id, _, _, _, _),
             .fileChange(let id, _, _),
             .enteredReviewMode(let id, _),
             .exitedReviewMode(let id, _),
             .contextCompaction(let id):
            return id
        case .unsupported(let id):
            return id ?? UUID().uuidString
        }
    }
}

extension RemoteAppServerThreadItem: Codable {
    fileprivate enum CodingKeys: String, CodingKey {
        case type
        case id
        case content
        case text
        case summary
        case command
        case cwd
        case status
        case aggregatedOutput
        case changes
        case review
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let id = try? container.decode(String.self, forKey: .id)

        // Thread items are one of the highest-churn app-server payloads. We
        // decode recognized shapes strictly enough to catch schema drift on
        // known fields, but still retain the item id for unknown future types.
        switch type {
        case "userMessage":
            self = .userMessage(
                id: try container.decode(String.self, forKey: .id),
                content: try container.decode([RemoteAppServerUserInput].self, forKey: .content)
            )
        case "agentMessage":
            self = .agentMessage(
                id: try container.decode(String.self, forKey: .id),
                text: try container.decode(String.self, forKey: .text)
            )
        case "reasoning":
            self = .reasoning(
                id: try container.decode(String.self, forKey: .id),
                summary: try container.decodeLossyStringArray(forKey: .summary, itemType: type),
                content: try container.decodeLossyStringArray(forKey: .content, itemType: type)
            )
        case "plan":
            self = .plan(
                id: try container.decode(String.self, forKey: .id),
                text: try container.decode(String.self, forKey: .text)
            )
        case "commandExecution":
            self = .commandExecution(
                id: try container.decode(String.self, forKey: .id),
                command: try container.decode(String.self, forKey: .command),
                cwd: try container.decode(String.self, forKey: .cwd),
                status: try container.decode(RemoteAppServerCommandExecutionStatus.self, forKey: .status),
                aggregatedOutput: try container.decodeLossyOptionalString(forKey: .aggregatedOutput, itemType: type)
            )
        case "fileChange":
            self = .fileChange(
                id: try container.decode(String.self, forKey: .id),
                changes: try container.decodeLossyFileChanges(forKey: .changes, itemType: type),
                status: try container.decode(RemoteAppServerPatchApplyStatus.self, forKey: .status)
            )
        case "enteredReviewMode":
            self = .enteredReviewMode(
                id: try container.decode(String.self, forKey: .id),
                review: try container.decode(String.self, forKey: .review)
            )
        case "exitedReviewMode":
            self = .exitedReviewMode(
                id: try container.decode(String.self, forKey: .id),
                review: try container.decode(String.self, forKey: .review)
            )
        case "contextCompaction":
            self = .contextCompaction(id: try container.decode(String.self, forKey: .id))
        default:
            self = .unsupported(id: id)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .userMessage(let id, let content):
            try container.encode("userMessage", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(content, forKey: .content)
        case .agentMessage(let id, let text):
            try container.encode("agentMessage", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(text, forKey: .text)
        case .reasoning(let id, let summary, let content):
            try container.encode("reasoning", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(summary, forKey: .summary)
            try container.encode(content, forKey: .content)
        case .plan(let id, let text):
            try container.encode("plan", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(text, forKey: .text)
        case .commandExecution(let id, let command, let cwd, let status, let aggregatedOutput):
            try container.encode("commandExecution", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(command, forKey: .command)
            try container.encode(cwd, forKey: .cwd)
            try container.encode(status, forKey: .status)
            try container.encodeIfPresent(aggregatedOutput, forKey: .aggregatedOutput)
        case .fileChange(let id, let changes, let status):
            try container.encode("fileChange", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(changes, forKey: .changes)
            try container.encode(status, forKey: .status)
        case .enteredReviewMode(let id, let review):
            try container.encode("enteredReviewMode", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(review, forKey: .review)
        case .exitedReviewMode(let id, let review):
            try container.encode("exitedReviewMode", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(review, forKey: .review)
        case .contextCompaction(let id):
            try container.encode("contextCompaction", forKey: .type)
            try container.encode(id, forKey: .id)
        case .unsupported(let id):
            try container.encode("unsupported", forKey: .type)
            try container.encodeIfPresent(id, forKey: .id)
        }
    }
}

private extension KeyedDecodingContainer where K == RemoteAppServerThreadItem.CodingKeys {
    // These helpers intentionally fail with an item-qualified decoding message
    // instead of silently defaulting malformed values. Unknown item types are
    // tolerated above; known item types should still surface contract breaks.
    func decodeLossyStringArray(
        forKey key: K,
        itemType: String
    ) throws -> [String] {
        guard contains(key) else { return [] }
        do {
            return try decode([String].self, forKey: key)
        } catch {
            throw RemoteAppServerThreadItem.decodingFailure(
                key: key,
                itemType: itemType,
                expected: "[String]",
                underlying: error
            )
        }
    }

    func decodeLossyOptionalString(
        forKey key: K,
        itemType: String
    ) throws -> String? {
        guard contains(key) else { return nil }
        do {
            return try decodeNil(forKey: key) ? nil : decode(String.self, forKey: key)
        } catch {
            throw RemoteAppServerThreadItem.decodingFailure(
                key: key,
                itemType: itemType,
                expected: "String?",
                underlying: error
            )
        }
    }

    func decodeLossyFileChanges(
        forKey key: K,
        itemType: String
    ) throws -> [RemoteAppServerFileUpdateChange] {
        guard contains(key) else { return [] }
        do {
            return try decode([RemoteAppServerFileUpdateChange].self, forKey: key)
        } catch {
            throw RemoteAppServerThreadItem.decodingFailure(
                key: key,
                itemType: itemType,
                expected: "[RemoteAppServerFileUpdateChange]",
                underlying: error
            )
        }
    }
}

private extension RemoteAppServerThreadItem {
    static func decodingFailure(
        key: CodingKeys,
        itemType: String,
        expected: String,
        underlying: Error
    ) -> DecodingError {
        let context = DecodingError.Context(
            codingPath: [key],
            debugDescription: "Failed to decode \(itemType).\(key.stringValue) as \(expected): \(underlying)"
        )
        return .dataCorrupted(context)
    }
}
