//
//  SessionRuntimeInfo.swift
//  CodexIsland
//
//  Shared runtime metadata for model selection and context window usage.
//

import Foundation

nonisolated struct SessionTokenUsage: Equatable, Sendable {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
    let totalTokens: Int

    static let zero = SessionTokenUsage(
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        totalTokens: 0
    )

    private static let baselineTokens = 12_000

    var tokensInContextWindow: Int {
        max(totalTokens, 0)
    }

    func percentOfContextWindowRemaining(_ contextWindow: Int) -> Int {
        guard contextWindow > Self.baselineTokens else { return 0 }

        let effectiveWindow = contextWindow - Self.baselineTokens
        let used = max(tokensInContextWindow - Self.baselineTokens, 0)
        let remaining = max(effectiveWindow - used, 0)
        let ratio = Double(remaining) / Double(effectiveWindow)
        return Int((ratio * 100.0).rounded().clamped(to: 0 ... 100))
    }
}

nonisolated struct SessionTokenUsageInfo: Equatable, Sendable {
    let totalTokenUsage: SessionTokenUsage
    let lastTokenUsage: SessionTokenUsage
    let modelContextWindow: Int?

    static let empty = SessionTokenUsageInfo(
        totalTokenUsage: .zero,
        lastTokenUsage: .zero,
        modelContextWindow: nil
    )

    var contextRemainingPercent: Int? {
        guard let modelContextWindow else { return nil }
        return lastTokenUsage.percentOfContextWindowRemaining(modelContextWindow)
    }
}

nonisolated struct SessionRuntimeInfo: Equatable, Sendable {
    var model: String?
    var reasoningEffort: String?
    var modelProvider: String?
    var tokenUsage: SessionTokenUsageInfo?

    static let empty = SessionRuntimeInfo(
        model: nil,
        reasoningEffort: nil,
        modelProvider: nil,
        tokenUsage: nil
    )
}

private extension Comparable {
    nonisolated func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
