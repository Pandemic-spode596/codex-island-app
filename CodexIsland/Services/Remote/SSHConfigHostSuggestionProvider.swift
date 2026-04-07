//
//  SSHConfigHostSuggestionProvider.swift
//  CodexIsland
//
//  Lightweight SSH config discovery used to suggest host aliases in the remote hosts UI.
//

import Combine
import Foundation

struct SSHConfigHostSuggestion: Identifiable, Equatable, Sendable {
    let alias: String
    let hostname: String?
    let user: String?
    let port: Int?

    var id: String { alias }

    /// Preview text shown under the alias in the picker. Keep it intentionally sparse so the
    /// suggestion list stays lightweight and never competes with the user's free-form ssh target.
    var resolutionSummary: String? {
        let normalizedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedHostname = hostname?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasMeaningfulHostname = normalizedHostname.map { $0 != normalizedAlias } ?? false
        let hasMeaningfulPort = (port ?? 22) != 22

        guard user != nil || hasMeaningfulHostname || hasMeaningfulPort else {
            return nil
        }

        var address = ""
        if let hostname, !hostname.isEmpty {
            if let user, !user.isEmpty {
                address = "\(user)@\(hostname)"
            } else {
                address = hostname
            }
        } else if let user, !user.isEmpty {
            address = user
        }

        if let port, port != 22 {
            if address.isEmpty {
                address = "port \(port)"
            } else {
                address += ":\(port)"
            }
        }

        return address.isEmpty ? nil : address
    }

    func matches(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let normalized = trimmed.lowercased()
        if alias.lowercased().contains(normalized) {
            return true
        }
        if hostname?.lowercased().contains(normalized) == true {
            return true
        }
        if user?.lowercased().contains(normalized) == true {
            return true
        }
        if resolutionSummary?.lowercased().contains(normalized) == true {
            return true
        }
        return false
    }
}

actor SSHConfigHostSuggestionProvider {
    static let shared = SSHConfigHostSuggestionProvider()

    private let fileManager: FileManager
    private let processExecutor: any ProcessExecuting
    private let configURL: URL
    private let aliasDiscovery: SSHConfigAliasDiscovery
    private let resolvedHostParser = SSHConfigResolvedHostParser()

    init(
        fileManager: FileManager = .default,
        processExecutor: any ProcessExecuting = ProcessExecutor.shared,
        configURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.processExecutor = processExecutor
        self.configURL = configURL ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        self.aliasDiscovery = SSHConfigAliasDiscovery(fileManager: fileManager)
    }

    func loadSuggestions() async -> [SSHConfigHostSuggestion] {
        // SSH config is only a convenience input source for the UI. If the file is missing or
        // partially unreadable we simply return no suggestions rather than surfacing an error.
        guard fileManager.fileExists(atPath: configURL.path) else {
            return []
        }

        let aliases = aliasDiscovery.discoverAliases(from: configURL)
        guard !aliases.isEmpty else {
            return []
        }

        var suggestions: [SSHConfigHostSuggestion] = []
        suggestions.reserveCapacity(aliases.count)

        for alias in aliases {
            let resolved = await resolveHost(alias: alias)
            suggestions.append(
                SSHConfigHostSuggestion(
                    alias: alias,
                    hostname: resolved.hostname,
                    user: resolved.user,
                    port: resolved.port
                )
            )
        }

        return suggestions
    }

    private func resolveHost(alias: String) async -> SSHConfigResolvedHost {
        // Delegate final expansion to `ssh -G` so preview text reflects OpenSSH's own precedence
        // rules instead of duplicating HostName/User/Port resolution in Swift.
        let result = await processExecutor.runWithResult(
            "/usr/bin/ssh",
            arguments: ["-G", "-F", configURL.path, alias]
        )

        guard case .success(let processResult) = result else {
            return SSHConfigResolvedHost()
        }

        return resolvedHostParser.parse(processResult.output)
    }
}

@MainActor
final class SSHConfigSuggestionStore: ObservableObject {
    @Published private(set) var suggestions: [SSHConfigHostSuggestion] = []

    private let provider: SSHConfigHostSuggestionProvider
    private var refreshTask: Task<Void, Never>?
    private var hasLoaded = false

    init(provider: SSHConfigHostSuggestionProvider = .shared) {
        self.provider = provider
    }

    func refreshIfNeeded() {
        // Initial load is lazy because the remote hosts sheet should stay cheap until the user
        // actually focuses the SSH target field or opens the host editor.
        guard !hasLoaded else { return }
        hasLoaded = true
        refresh()
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [provider] in
            let loadedSuggestions = await provider.loadSuggestions()
            guard !Task.isCancelled else { return }
            self.suggestions = loadedSuggestions
        }
    }
}
