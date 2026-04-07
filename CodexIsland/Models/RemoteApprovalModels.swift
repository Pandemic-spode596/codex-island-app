//
//  RemoteApprovalModels.swift
//  CodexIsland
//
//  Shared remote RPC and approval models used by remote session state.
//

import Foundation

nonisolated enum RemoteRPCID: Hashable, Codable, Sendable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
            return
        }

        let stringValue = try container.decode(String.self)
        self = .string(stringValue)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }
}

nonisolated enum RemoteApprovalKind: String, Sendable {
    case commandExecution
    case fileChange
    case permissions
}

// RemotePendingApproval stores the server-facing request identity alongside the
// user-facing approval metadata so the same model can drive both UI rendering
// and approval responses.
nonisolated struct RemotePendingApproval: Identifiable, Equatable, Sendable {
    let id: String
    let requestId: RemoteRPCID
    let kind: RemoteApprovalKind
    let itemId: String
    let threadId: String
    let turnId: String
    let title: String
    let detail: String?
    let requestedPermissions: InteractionPermissionProfile
    let availableActions: [PendingApprovalAction]

    var formattedInput: String? {
        switch kind {
        case .permissions:
            return requestedPermissions.summary ?? detail
        case .commandExecution, .fileChange:
            return detail
        }
    }
}

nonisolated struct RemoteThreadTurnContext: Equatable, Sendable {
    var model: String?
    var reasoningEffort: RemoteAppServerReasoningEffort?
    var approvalPolicy: RemoteAppServerApprovalPolicy?
    var approvalsReviewer: RemoteAppServerApprovalsReviewer?
    var sandboxPolicy: RemoteAppServerSandboxPolicy?
    var serviceTier: RemoteAppServerServiceTier?
    var collaborationMode: RemoteAppServerCollaborationMode?

    static let empty = RemoteThreadTurnContext(
        model: nil,
        reasoningEffort: nil,
        approvalPolicy: nil,
        approvalsReviewer: nil,
        sandboxPolicy: nil,
        serviceTier: nil,
        collaborationMode: nil
    )

    var effectiveModel: String? {
        collaborationMode?.settings.model ?? model
    }

    var effectiveReasoningEffort: RemoteAppServerReasoningEffort? {
        collaborationMode?.settings.reasoningEffort ?? reasoningEffort
    }
}

extension RemotePendingApproval {
    nonisolated var pendingKind: PendingApprovalKind {
        switch kind {
        case .commandExecution:
            return .commandExecution
        case .fileChange:
            return .fileChange
        case .permissions:
            return .permissions
        }
    }
}
