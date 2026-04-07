//
//  RemoteAppServerProtocol+RequestValues.swift
//  CodexIsland
//
//  Outbound request payload helpers and token usage bridges for the app-server protocol.
//

import Foundation

extension RemoteAppServerApprovalPolicy {
    nonisolated var requestValue: String? {
        switch self {
        case .untrusted:
            return "untrusted"
        case .onFailure:
            return "on-failure"
        case .onRequest:
            return "on-request"
        case .never:
            return "never"
        case .granular, .unsupported:
            return nil
        }
    }
}

extension RemoteAppServerSandboxMode {
    nonisolated var requestValue: String {
        switch self {
        case .readOnly:
            return "read-only"
        case .workspaceWrite:
            return "workspace-write"
        case .dangerFullAccess:
            return "danger-full-access"
        case .externalSandbox:
            return "external-sandbox"
        }
    }
}

extension RemoteAppServerSandboxPolicy {
    // requestValue intentionally serializes the server's expected request
    // schema rather than mirroring Codable output. The transport layer posts
    // this dictionary as JSON, and the server currently expects camelCase keys
    // plus the nested readOnlyAccess marker for workspace-write mode.
    nonisolated var requestValue: [String: Any] {
        switch mode {
        case .dangerFullAccess:
            return ["type": "dangerFullAccess"]
        case .readOnly:
            return [
                "type": "readOnly",
                "networkAccess": networkAccessEnabled ?? false
            ]
        case .workspaceWrite:
            return [
                "type": "workspaceWrite",
                "networkAccess": networkAccessEnabled ?? false,
                "writableRoots": writableRoots,
                "excludeTmpdirEnvVar": excludeTmpdirEnvVar,
                "excludeSlashTmp": excludeSlashTmp,
                "readOnlyAccess": ["type": "fullAccess"]
            ]
        case .externalSandbox:
            return ["type": "externalSandbox"]
        }
    }
}

extension RemoteAppServerCollaborationMode {
    nonisolated var requestValue: [String: Any] {
        var payloadSettings: [String: Any] = [
            "model": settings.model
        ]
        if let reasoningEffort = settings.reasoningEffort?.rawValue {
            payloadSettings["reasoning_effort"] = reasoningEffort
        }
        if let developerInstructions = settings.developerInstructions {
            payloadSettings["developerInstructions"] = developerInstructions
        } else {
            payloadSettings["developerInstructions"] = NSNull()
        }

        return [
            "mode": mode.rawValue,
            "settings": payloadSettings
        ]
    }
}

extension RemoteAppServerThreadTokenUsage {
    nonisolated var sessionValue: SessionTokenUsageInfo {
        SessionTokenUsageInfo(
            totalTokenUsage: total.sessionValue,
            lastTokenUsage: last.sessionValue,
            modelContextWindow: modelContextWindow
        )
    }
}

extension RemoteAppServerTokenUsageBreakdown {
    nonisolated var sessionValue: SessionTokenUsage {
        SessionTokenUsage(
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            totalTokens: totalTokens
        )
    }
}

nonisolated func remoteDecodeValue<T: Decodable>(_ value: AnyCodable, as type: T.Type) throws -> T {
    // Remote envelopes arrive as AnyCodable because params/result payloads vary
    // by method. Re-encoding through JSON keeps decoding rules consistent with
    // the rest of the protocol models and avoids handwritten dictionary casts.
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(type, from: data)
}
