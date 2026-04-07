//
//  SSHConfigResolvedHost.swift
//  CodexIsland
//
//  Parsed `ssh -G` host preview fields for remote host suggestions.
//

import Foundation

struct SSHConfigResolvedHost: Equatable, Sendable {
    var hostname: String?
    var user: String?
    var port: Int?
}

struct SSHConfigResolvedHostParser {
    func parse(_ output: String) -> SSHConfigResolvedHost {
        var resolved = SSHConfigResolvedHost()

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
