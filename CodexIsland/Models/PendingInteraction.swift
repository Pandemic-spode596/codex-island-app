//
//  PendingInteraction.swift
//  CodexIsland
//
//  Unified models for user-facing Codex interactions that require input.
//

import Foundation

// MARK: - Transport

// Pending interactions normalize local Codex tool calls, remote app-server
// requests, and hook approvals into one UI contract so the same SwiftUI bars
// can render and respond to every interactive stop point.
nonisolated enum PendingInteractionTransport: Equatable, Sendable {
    case codexLocal(callId: String?, turnId: String?)
    case remoteAppServer(requestId: RemoteRPCID)
    case hookPermission(toolUseId: String)

    var isLocalCodex: Bool {
        if case .codexLocal = self {
            return true
        }
        return false
    }
}

// MARK: - Permissions

nonisolated struct InteractionPermissionProfile: Equatable, Sendable {
    var networkEnabled: Bool?
    var readRoots: [String]
    var writeRoots: [String]

    static let none = InteractionPermissionProfile(
        networkEnabled: nil,
        readRoots: [],
        writeRoots: []
    )

    var isEmpty: Bool {
        networkEnabled == nil && readRoots.isEmpty && writeRoots.isEmpty
    }

    var summary: String? {
        var parts: [String] = []
        if let networkEnabled {
            parts.append(networkEnabled ? "network: enabled" : "network: restricted")
        }
        if !readRoots.isEmpty {
            parts.append("read: \(readRoots.joined(separator: ", "))")
        }
        if !writeRoots.isEmpty {
            parts.append("write: \(writeRoots.joined(separator: ", "))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

// MARK: - Questions

nonisolated struct PendingInteractionOption: Equatable, Sendable {
    let label: String
    let description: String?
}

// A question may still be rendered read-only even when it is user-visible; the
// inline composer only supports non-secret free-text prompts or explicit choice
// lists that can be mapped back to answer payloads.
nonisolated struct PendingInteractionQuestion: Equatable, Sendable {
    let id: String
    let header: String
    let question: String
    let options: [PendingInteractionOption]
    let isOther: Bool
    let isSecret: Bool

    var isChoiceQuestion: Bool {
        !options.isEmpty
    }

    var supportsInlineResponse: Bool {
        if isSecret {
            return false
        }
        if isChoiceQuestion {
            return true
        }
        return !isOther
    }
}

// MARK: - Interaction Payloads

nonisolated struct PendingUserInputInteraction: Identifiable, Equatable, Sendable {
    nonisolated enum PresentationMode: Equatable, Sendable {
        case inline
        case readOnly
        case terminalOnly
    }

    let id: String
    let title: String
    let questions: [PendingInteractionQuestion]
    let transport: PendingInteractionTransport

    var summaryText: String {
        questions.first?.question ?? title
    }

    var supportsInlineResponse: Bool {
        !questions.isEmpty && questions.allSatisfy(\.supportsInlineResponse)
    }

    func presentationMode(canRespondInline: Bool) -> PresentationMode {
        guard !questions.isEmpty else {
            return .terminalOnly
        }
        return canRespondInline ? .inline : .readOnly
    }

    var remoteRequestID: RemoteRPCID {
        if case .remoteAppServer(let requestId) = transport {
            return requestId
        }
        return .string(id)
    }
}

// MARK: - Approvals

nonisolated enum PendingApprovalKind: String, Equatable, Sendable {
    case commandExecution
    case fileChange
    case permissions
    case generic
}

nonisolated enum PendingApprovalAction: String, CaseIterable, Equatable, Sendable, Hashable {
    case allow
    case allowForSession
    case deny
    case cancel

    var buttonTitle: String {
        switch self {
        case .allow:
            return "Allow"
        case .allowForSession:
            return "Session"
        case .deny:
            return "Deny"
        case .cancel:
            return "Cancel"
        }
    }
}

nonisolated struct PendingApprovalInteraction: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let kind: PendingApprovalKind
    let detail: String?
    let requestedPermissions: InteractionPermissionProfile
    let availableActions: [PendingApprovalAction]
    let transport: PendingInteractionTransport

    var summaryText: String {
        // Detail wins because command/file approvals usually need to show the
        // concrete payload first. Permission-only prompts fall back to the
        // synthesized permission summary when no explicit detail was provided.
        if let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return detail
        }
        if let permissionsSummary = requestedPermissions.summary, !permissionsSummary.isEmpty {
            return permissionsSummary
        }
        return title
    }
}

// MARK: - Unified Interaction

nonisolated enum PendingInteraction: Identifiable, Equatable, Sendable {
    case userInput(PendingUserInputInteraction)
    case approval(PendingApprovalInteraction)

    var id: String {
        switch self {
        case .userInput(let interaction):
            return interaction.id
        case .approval(let interaction):
            return interaction.id
        }
    }

    var title: String {
        switch self {
        case .userInput(let interaction):
            return interaction.title
        case .approval(let interaction):
            return interaction.title
        }
    }

    var summaryText: String {
        switch self {
        case .userInput(let interaction):
            return interaction.summaryText
        case .approval(let interaction):
            return interaction.summaryText
        }
    }

    var transport: PendingInteractionTransport {
        switch self {
        case .userInput(let interaction):
            return interaction.transport
        case .approval(let interaction):
            return interaction.transport
        }
    }

    var isApproval: Bool {
        if case .approval = self {
            return true
        }
        return false
    }

    var isUserInput: Bool {
        if case .userInput = self {
            return true
        }
        return false
    }
}

// request_user_input may legally produce one answer, many answers, or no
// answers for the same question id depending on question type and UI path.
nonisolated struct PendingInteractionAnswerPayload: Equatable, Sendable {
    // Values stay as arrays because request_user_input can return either a
    // single answer or a multi-select choice list for the same question id.
    let answers: [String: [String]]
}
