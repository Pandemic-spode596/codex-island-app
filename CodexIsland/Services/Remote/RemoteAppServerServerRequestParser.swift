//
//  RemoteAppServerServerRequestParser.swift
//  CodexIsland
//
//  Parsing helpers for inbound app-server approval and request_user_input payloads.
//

import Foundation

struct RemoteAppServerServerRequestParser {
    let hostId: String

    func commandApproval(requestId: RemoteRPCID, params: Any) -> RemotePendingApproval? {
        guard let params = params as? [String: Any],
              let threadId = params["threadId"] as? String,
              let turnId = params["turnId"] as? String,
              let itemId = params["itemId"] as? String else {
            return nil
        }

        let command = params["command"] as? String
        let reason = params["reason"] as? String
        let availableActions = commandApprovalActions(params["availableDecisions"]) ?? [.allow, .cancel]

        return RemotePendingApproval(
            id: "approval-\(hostId)-\(itemId)",
            requestId: requestId,
            kind: .commandExecution,
            itemId: itemId,
            threadId: threadId,
            turnId: turnId,
            title: "Command Execution",
            detail: command ?? reason,
            requestedPermissions: permissionProfile(params["additionalPermissions"] as? [String: Any]),
            availableActions: availableActions
        )
    }

    func fileApproval(requestId: RemoteRPCID, params: Any) -> RemotePendingApproval? {
        guard let params = params as? [String: Any],
              let threadId = params["threadId"] as? String,
              let turnId = params["turnId"] as? String,
              let itemId = params["itemId"] as? String else {
            return nil
        }

        return RemotePendingApproval(
            id: "approval-\(hostId)-\(itemId)",
            requestId: requestId,
            kind: .fileChange,
            itemId: itemId,
            threadId: threadId,
            turnId: turnId,
            title: "File Change",
            detail: params["reason"] as? String,
            requestedPermissions: .none,
            availableActions: [.allow, .allowForSession, .deny, .cancel]
        )
    }

    func permissionsApproval(requestId: RemoteRPCID, params: Any) -> RemotePendingApproval? {
        guard let params = params as? [String: Any],
              let threadId = params["threadId"] as? String,
              let turnId = params["turnId"] as? String,
              let itemId = params["itemId"] as? String else {
            return nil
        }

        return RemotePendingApproval(
            id: "approval-\(hostId)-\(itemId)",
            requestId: requestId,
            kind: .permissions,
            itemId: itemId,
            threadId: threadId,
            turnId: turnId,
            title: "Permissions Request",
            detail: params["reason"] as? String,
            requestedPermissions: permissionProfile(params["permissions"] as? [String: Any]),
            availableActions: [.allow, .allowForSession, .deny]
        )
    }

    func userInputRequest(
        requestId: RemoteRPCID,
        params: Any
    ) -> (threadId: String, interaction: PendingUserInputInteraction)? {
        guard let params = params as? [String: Any],
              let threadId = params["threadId"] as? String,
              let _ = params["turnId"] as? String,
              let itemId = params["itemId"] as? String,
              let rawQuestions = params["questions"] as? [[String: Any]] else {
            return nil
        }

        let questions = rawQuestions.compactMap { question -> PendingInteractionQuestion? in
            guard let id = question["id"] as? String,
                  let header = question["header"] as? String,
                  let prompt = question["question"] as? String else {
                return nil
            }
            let options = (question["options"] as? [[String: Any]] ?? []).compactMap { option -> PendingInteractionOption? in
                guard let label = option["label"] as? String else { return nil }
                return PendingInteractionOption(
                    label: label,
                    description: option["description"] as? String
                )
            }
            return PendingInteractionQuestion(
                id: id,
                header: header,
                question: prompt,
                options: options,
                isOther: question["isOther"] as? Bool ?? false,
                isSecret: question["isSecret"] as? Bool ?? false
            )
        }

        guard !questions.isEmpty else { return nil }

        return (
            threadId: threadId,
            interaction: PendingUserInputInteraction(
                id: itemId,
                title: "Codex needs your input",
                questions: questions,
                transport: .remoteAppServer(requestId: requestId)
            )
        )
    }

    func permissionGrantPayload(from profile: InteractionPermissionProfile) -> [String: Any] {
        var payload: [String: Any] = [:]
        if let networkEnabled = profile.networkEnabled {
            payload["network"] = ["enabled": networkEnabled]
        }
        var fileSystem: [String: Any] = [:]
        if !profile.readRoots.isEmpty {
            fileSystem["read"] = profile.readRoots
        }
        if !profile.writeRoots.isEmpty {
            fileSystem["write"] = profile.writeRoots
        }
        if !fileSystem.isEmpty {
            payload["fileSystem"] = fileSystem
        }
        return payload
    }

    private func commandApprovalActions(_ value: Any?) -> [PendingApprovalAction]? {
        guard let rawActions = value as? [Any] else { return nil }
        let actions = rawActions.compactMap { raw -> PendingApprovalAction? in
            if let raw = raw as? String {
                switch raw {
                case "accept":
                    return .allow
                case "acceptForSession":
                    return .allowForSession
                case "decline":
                    return .deny
                case "cancel":
                    return .cancel
                default:
                    return nil
                }
            }
            if let raw = raw as? [String: Any] {
                if raw["acceptWithExecpolicyAmendment"] != nil {
                    return nil
                }
                if raw["applyNetworkPolicyAmendment"] != nil {
                    return nil
                }
            }
            return nil
        }
        return actions.isEmpty ? nil : actions
    }

    private func permissionProfile(_ value: [String: Any]?) -> InteractionPermissionProfile {
        guard let value else { return .none }
        let network = value["network"] as? [String: Any]
        let fileSystem = value["fileSystem"] as? [String: Any]
        return InteractionPermissionProfile(
            networkEnabled: network?["enabled"] as? Bool,
            readRoots: fileSystem?["read"] as? [String] ?? [],
            writeRoots: fileSystem?["write"] as? [String] ?? []
        )
    }
}
