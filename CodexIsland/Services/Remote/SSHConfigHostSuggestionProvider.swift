//
//  SSHConfigHostSuggestionProvider.swift
//  CodexIsland
//
//  Lightweight SSH config discovery used to suggest host aliases in the remote hosts UI.
//

import Combine
import Darwin
import Foundation

struct SSHConfigHostSuggestion: Identifiable, Equatable, Sendable {
    let alias: String
    let hostname: String?
    let user: String?
    let port: Int?

    var id: String { alias }

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
    private struct ResolvedHost {
        var hostname: String?
        var user: String?
        var port: Int?
    }

    static let shared = SSHConfigHostSuggestionProvider()

    private let fileManager: FileManager
    private let processExecutor: any ProcessExecuting
    private let configURL: URL

    init(
        fileManager: FileManager = .default,
        processExecutor: any ProcessExecuting = ProcessExecutor.shared,
        configURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.processExecutor = processExecutor
        self.configURL = configURL ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    func loadSuggestions() async -> [SSHConfigHostSuggestion] {
        guard fileManager.fileExists(atPath: configURL.path) else {
            return []
        }

        var visitedPaths: Set<String> = []
        let aliases = discoverAliases(from: configURL, visitedPaths: &visitedPaths)
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

    private func discoverAliases(from fileURL: URL, visitedPaths: inout Set<String>) -> [String] {
        let normalizedPath = fileURL.standardizedFileURL.path
        guard visitedPaths.insert(normalizedPath).inserted else {
            return []
        }

        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }

        var aliases: [String] = []
        var seenAliases: Set<String> = []

        for rawLine in contents.components(separatedBy: .newlines) {
            guard let (keyword, value) = parseDirective(from: rawLine) else {
                continue
            }

            switch keyword {
            case "host":
                for token in tokenize(value) where isConcreteHostAlias(token) {
                    let alias = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard seenAliases.insert(alias).inserted else { continue }
                    aliases.append(alias)
                }
            case "include":
                for includePattern in tokenize(value) {
                    for includeURL in resolveIncludePatterns(includePattern, relativeTo: fileURL) {
                        let nestedAliases = discoverAliases(from: includeURL, visitedPaths: &visitedPaths)
                        for alias in nestedAliases where seenAliases.insert(alias).inserted {
                            aliases.append(alias)
                        }
                    }
                }
            default:
                continue
            }
        }

        return aliases
    }

    private func parseDirective(from rawLine: String) -> (String, String)? {
        let line = stripComments(from: rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let rawKeyword = parts.first else { return nil }

        let keyword = rawKeyword.lowercased()
        let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (keyword, value)
    }

    private func stripComments(from rawLine: String) -> String {
        var result = ""
        var inSingleQuotes = false
        var inDoubleQuotes = false
        var isEscaped = false

        for character in rawLine {
            if isEscaped {
                result.append(character)
                isEscaped = false
                continue
            }

            if character == "\\" {
                isEscaped = true
                result.append(character)
                continue
            }

            if character == "\"" && !inSingleQuotes {
                inDoubleQuotes.toggle()
                result.append(character)
                continue
            }

            if character == "'" && !inDoubleQuotes {
                inSingleQuotes.toggle()
                result.append(character)
                continue
            }

            if character == "#" && !inSingleQuotes && !inDoubleQuotes {
                break
            }

            result.append(character)
        }

        return result
    }

    private func tokenize(_ value: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingleQuotes = false
        var inDoubleQuotes = false
        var isEscaped = false

        for character in value {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }

            if character == "\\" {
                isEscaped = true
                continue
            }

            if character == "\"" && !inSingleQuotes {
                inDoubleQuotes.toggle()
                continue
            }

            if character == "'" && !inDoubleQuotes {
                inSingleQuotes.toggle()
                continue
            }

            if character.isWhitespace && !inSingleQuotes && !inDoubleQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                continue
            }

            current.append(character)
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    private func isConcreteHostAlias(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.contains("*"), !trimmed.contains("?") else { return false }
        guard !trimmed.hasPrefix("!") else { return false }
        return true
    }

    private func resolveIncludePatterns(_ pattern: String, relativeTo fileURL: URL) -> [URL] {
        guard !pattern.isEmpty else { return [] }

        let expandedPattern = NSString(string: pattern).expandingTildeInPath
        let resolvedPattern: String
        if expandedPattern.hasPrefix("/") {
            resolvedPattern = expandedPattern
        } else {
            resolvedPattern = fileURL.deletingLastPathComponent().appendingPathComponent(expandedPattern).path
        }

        var globResult = glob_t()
        defer { globfree(&globResult) }

        let status = glob(resolvedPattern, 0, nil, &globResult)
        guard status == 0 else { return [] }

        return (0..<Int(globResult.gl_pathc)).compactMap { index in
            guard let path = globResult.gl_pathv[index] else { return nil }
            return URL(fileURLWithPath: String(cString: path))
        }
    }

    private func resolveHost(alias: String) async -> ResolvedHost {
        let result = await processExecutor.runWithResult(
            "/usr/bin/ssh",
            arguments: ["-G", "-F", configURL.path, alias]
        )

        guard case .success(let processResult) = result else {
            return ResolvedHost()
        }

        return parseResolvedHost(from: processResult.output)
    }

    private func parseResolvedHost(from output: String) -> ResolvedHost {
        var resolved = ResolvedHost()

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard let rawKeyword = parts.first, parts.count > 1 else { continue }

            let keyword = rawKeyword.lowercased()
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)

            switch keyword {
            case "hostname":
                resolved.hostname = value.isEmpty ? nil : value
            case "user":
                resolved.user = value.isEmpty ? nil : value
            case "port":
                resolved.port = Int(value)
            default:
                continue
            }
        }

        return resolved
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
