//
//  RemoteSessionState.swift
//  CodexIsland
//
//  App-server backed remote thread state used by the UI.
//

import Foundation

// RemoteThreadState is the UI-facing projection of one logical remote session.
// It may represent a raw app-server thread directly, or a collapsed view chosen
// from several raw threads that share the same host/cwd identity.
nonisolated struct RemoteThreadState: Identifiable, Equatable, Sendable {
    let hostId: String
    let hostName: String
    var threadId: String
    var logicalSessionId: String

    var preview: String
    var name: String?
    var cwd: String
    var phase: SessionPhase
    var lastActivity: Date
    var createdAt: Date
    var updatedAt: Date
    var lastMessage: String?
    var lastMessageRole: String?
    var lastToolName: String?
    var lastUserMessageDate: Date?
    var history: [ChatHistoryItem]
    var activeTurnId: String?
    var isLoaded: Bool
    var canSteerTurn: Bool
    var pendingApproval: RemotePendingApproval?
    var pendingInteractions: [PendingInteraction]
    var connectionState: RemoteHostConnectionState
    var turnContext: RemoteThreadTurnContext
    var tokenUsage: SessionTokenUsageInfo?

    var id: String { stableId }

    var stableId: String {
        logicalSessionId
    }

    var rawStableId: String {
        "remote-\(hostId)-\(threadId)"
    }

    var displayTitle: String {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        if !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return preview
        }
        return hostName
    }

    var sourceLabel: String {
        "Remote • \(hostName)"
    }

    var sourceDetail: String {
        let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCwd.isEmpty else { return sourceLabel }
        return "\(sourceLabel) • \(trimmedCwd)"
    }

    var currentModel: String? {
        turnContext.effectiveModel
    }

    var currentReasoningEffort: RemoteAppServerReasoningEffort? {
        turnContext.effectiveReasoningEffort
    }

    var contextRemainingPercent: Int? {
        tokenUsage?.contextRemainingPercent
    }

    var canStartTurn: Bool {
        connectionState.isConnected &&
            primaryPendingInteraction == nil &&
            (phase == .idle || phase == .waitingForInput)
    }

    var canSendMessage: Bool {
        connectionState.isConnected &&
            primaryPendingInteraction == nil &&
            (canStartTurn || canSteerTurn)
    }

    var needsHydration: Bool {
        !isLoaded
    }

    var canInterrupt: Bool {
        connectionState.isConnected && (phase == .processing || phase == .compacting)
    }

    var approvalToolName: String? {
        if case .approval(let interaction) = primaryPendingInteraction {
            return interaction.title
        }
        return pendingApproval?.title
    }

    var pendingToolInput: String? {
        if case .approval(let interaction) = primaryPendingInteraction {
            return interaction.summaryText
        }
        return pendingApproval?.formattedInput
    }

    var primaryPendingInteraction: PendingInteraction? {
        // Prefer fully parsed PendingInteraction values when available. Older
        // server approval flows still arrive as RemotePendingApproval and are
        // bridged into the unified UI model lazily here.
        if let pending = pendingInteractions.first {
            return pending
        }
        if let approval = pendingApproval {
            return .approval(PendingApprovalInteraction(
                id: approval.id,
                title: approval.title,
                kind: approval.pendingKind,
                detail: approval.detail,
                requestedPermissions: approval.requestedPermissions,
                availableActions: approval.availableActions,
                transport: .remoteAppServer(requestId: approval.requestId)
            ))
        }
        return nil
    }

    var needsAttention: Bool {
        primaryPendingInteraction != nil || phase.needsAttention
    }

    var connectionFeedbackMessage: String? {
        connectionState.feedbackMessage
    }
}
