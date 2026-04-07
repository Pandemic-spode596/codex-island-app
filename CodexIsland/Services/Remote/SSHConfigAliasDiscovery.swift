//
//  SSHConfigAliasDiscovery.swift
//  CodexIsland
//
//  SSH config alias discovery and Include expansion for remote host suggestions.
//

import Darwin
import Foundation

struct SSHConfigAliasDiscovery {
    let fileManager: FileManager

    func discoverAliases(from fileURL: URL) -> [String] {
        var visitedPaths: Set<String> = []
        return discoverAliases(from: fileURL, visitedPaths: &visitedPaths)
    }

    private func discoverAliases(from fileURL: URL, visitedPaths: inout Set<String>) -> [String] {
        // OpenSSH allows recursive Include chains. Track normalized paths so loops or repeated
        // include fan-out do not duplicate aliases or recurse forever.
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
                // The suggestion list should only offer concrete aliases users can paste into the
                // SSH Target field. Wildcards and negated host patterns influence matching rules
                // inside ssh config, but they are not valid direct connection shortcuts.
                for token in tokenize(value) where isConcreteHostAlias(token) {
                    let alias = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard seenAliases.insert(alias).inserted else { continue }
                    aliases.append(alias)
                }
            case "include":
                // Includes are resolved relative to the current file, mirroring OpenSSH behavior
                // for nested config trees such as ~/.ssh/conf.d/*.conf.
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
        // SSH config comments start at "#" unless the character is protected by quoting. We keep
        // the parser minimal but quote-aware so Include paths and Host aliases survive intact.
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
        // Host/Include directives accept space-separated tokens with basic shell-like quoting.
        // We only need enough parsing to preserve quoted aliases and include globs faithfully.
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

        return (0 ..< Int(globResult.gl_pathc)).compactMap { index in
            guard let path = globResult.gl_pathv[index] else { return nil }
            return URL(fileURLWithPath: String(cString: path))
        }
    }
}
