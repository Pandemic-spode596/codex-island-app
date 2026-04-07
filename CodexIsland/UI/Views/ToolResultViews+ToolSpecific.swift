//
//  ToolResultViews+ToolSpecific.swift
//  CodexIsland
//
//  Tool-specific result renderers used by ToolResultContent.
//

import SwiftUI

struct EditInputDiffView: View {
    let input: [String: String]

    private var filename: String {
        if let path = input["file_path"] {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return "file"
    }

    private var oldString: String {
        input["old_string"] ?? ""
    }

    private var newString: String {
        input["new_string"] ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !oldString.isEmpty || !newString.isEmpty {
                SimpleDiffView(oldString: oldString, newString: newString, filename: filename)
            }
        }
    }
}

struct ReadResultContent: View {
    let result: ReadResult

    var body: some View {
        if !result.content.isEmpty {
            FileCodeView(
                filename: result.filename,
                content: result.content,
                startLine: result.startLine,
                totalLines: result.totalLines,
                maxLines: 10
            )
        }
    }
}

struct EditResultContent: View {
    let result: EditResult
    var toolInput: [String: String] = [:]

    private var oldString: String {
        if !result.oldString.isEmpty {
            return result.oldString
        }
        return toolInput["old_string"] ?? ""
    }

    private var newString: String {
        if !result.newString.isEmpty {
            return result.newString
        }
        return toolInput["new_string"] ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !oldString.isEmpty || !newString.isEmpty {
                SimpleDiffView(oldString: oldString, newString: newString, filename: result.filename)
            }

            if result.userModified {
                Text("(User modified)")
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.7))
            }
        }
    }
}

struct WriteResultContent: View {
    let result: WriteResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(result.type == .create ? "Created" : "Wrote")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                Text(result.filename)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }

            if result.type == .create && !result.content.isEmpty {
                CodePreview(content: result.content, maxLines: 8)
            } else if let patches = result.structuredPatch, !patches.isEmpty {
                DiffView(patches: patches)
            }
        }
    }
}

struct BashResultContent: View {
    let result: BashResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let bgId = result.backgroundTaskId {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                    Text("Background task: \(bgId)")
                        .font(.system(size: 10, design: .monospaced))
                }
                .foregroundColor(.blue.opacity(0.7))
            }

            if let interpretation = result.returnCodeInterpretation {
                Text(interpretation)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }

            if !result.stdout.isEmpty {
                CodePreview(content: result.stdout, maxLines: 15)
            }

            if !result.stderr.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("stderr:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.red.opacity(0.7))
                    Text(result.stderr)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.red.opacity(0.8))
                        .lineLimit(10)
                }
            }

            if !result.hasOutput && result.backgroundTaskId == nil && result.returnCodeInterpretation == nil {
                Text("(No content)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
    }
}

struct GrepResultContent: View {
    let result: GrepResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch result.mode {
            case .filesWithMatches:
                if result.filenames.isEmpty {
                    Text("No matches found")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                } else {
                    FileListView(files: result.filenames, limit: 10)
                }

            case .content:
                if let content = result.content, !content.isEmpty {
                    CodePreview(content: content, maxLines: 15)
                } else {
                    Text("No matches found")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                }

            case .count:
                Text("\(result.numFiles) files with matches")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }
}

struct GlobResultContent: View {
    let result: GlobResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if result.filenames.isEmpty {
                Text("No files found")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
            } else {
                FileListView(files: result.filenames, limit: 10)

                if result.truncated {
                    Text("... and more (truncated)")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
        }
    }
}

struct TodoWriteResultContent: View {
    let result: TodoWriteResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(result.newTodos.enumerated()), id: \.offset) { _, todo in
                HStack(spacing: 6) {
                    Image(systemName: todoIcon(for: todo.status))
                        .font(.system(size: 10))
                        .foregroundColor(todoColor(for: todo.status))
                        .frame(width: 12)

                    Text(todo.content)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(todo.status == "completed" ? 0.4 : 0.7))
                        .strikethrough(todo.status == "completed")
                        .lineLimit(2)
                }
            }
        }
    }

    private func todoIcon(for status: String) -> String {
        switch status {
        case "completed":
            return "checkmark.circle.fill"
        case "in_progress":
            return "circle.lefthalf.filled"
        default:
            return "circle"
        }
    }

    private func todoColor(for status: String) -> Color {
        switch status {
        case "completed":
            return .green.opacity(0.7)
        case "in_progress":
            return .orange.opacity(0.7)
        default:
            return .white.opacity(0.4)
        }
    }
}

struct TaskResultContent: View {
    let result: TaskResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(result.status.capitalized)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(statusColor)

                if let duration = result.totalDurationMs {
                    Text("\(formatDuration(duration))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }

                if let tools = result.totalToolUseCount {
                    Text("\(tools) tools")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            if !result.content.isEmpty {
                Text(result.content.prefix(200) + (result.content.count > 200 ? "..." : ""))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(5)
            }
        }
    }

    private var statusColor: Color {
        switch result.status {
        case "completed":
            return .green.opacity(0.7)
        case "in_progress":
            return .orange.opacity(0.7)
        case "failed", "error":
            return .red.opacity(0.7)
        default:
            return .white.opacity(0.5)
        }
    }

    private func formatDuration(_ ms: Int) -> String {
        if ms >= 60000 {
            return "\(ms / 60000)m \((ms % 60000) / 1000)s"
        } else if ms >= 1000 {
            return "\(ms / 1000)s"
        }
        return "\(ms)ms"
    }
}

struct WebFetchResultContent: View {
    let result: WebFetchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(result.code)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(result.code < 400 ? .green.opacity(0.7) : .red.opacity(0.7))

                Text(truncateUrl(result.url))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }

            if !result.result.isEmpty {
                Text(result.result.prefix(300) + (result.result.count > 300 ? "..." : ""))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(8)
            }
        }
    }

    private func truncateUrl(_ url: String) -> String {
        if url.count > 50 {
            return String(url.prefix(47)) + "..."
        }
        return url
    }
}

struct WebSearchResultContent: View {
    let result: WebSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if result.results.isEmpty {
                Text("No results found")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
            } else {
                ForEach(Array(result.results.prefix(5).enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.blue.opacity(0.8))
                            .lineLimit(1)

                        if !item.snippet.isEmpty {
                            Text(item.snippet)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(2)
                        }
                    }
                }

                if result.results.count > 5 {
                    Text("... and \(result.results.count - 5) more results")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
        }
    }
}

struct AskUserQuestionResultContent: View {
    let result: AskUserQuestionResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(result.questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 4) {
                    Text(question.question)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))

                    if let answer = result.answers["\(index)"] {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 9))
                            Text(answer)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.green.opacity(0.7))
                    }
                }
            }
        }
    }
}

struct BashOutputResultContent: View {
    let result: BashOutputResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Status: \(result.status)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))

                if let exitCode = result.exitCode {
                    Text("Exit: \(exitCode)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(exitCode == 0 ? .green.opacity(0.6) : .red.opacity(0.6))
                }
            }

            if !result.stdout.isEmpty {
                CodePreview(content: result.stdout, maxLines: 10)
            }

            if !result.stderr.isEmpty {
                Text(result.stderr)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.red.opacity(0.7))
                    .lineLimit(5)
            }
        }
    }
}

struct KillShellResultContent: View {
    let result: KillShellResult

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "xmark.circle")
                .font(.system(size: 11))
                .foregroundColor(.red.opacity(0.6))

            Text(result.message.isEmpty ? "Shell \(result.shellId) terminated" : result.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
        }
    }
}

struct ExitPlanModeResultContent: View {
    let result: ExitPlanModeResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let path = result.filePath {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10))
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundColor(.white.opacity(0.6))
            }

            if let plan = result.plan, !plan.isEmpty {
                Text(plan.prefix(200) + (plan.count > 200 ? "..." : ""))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(6)
            }
        }
    }
}

struct MCPResultContent: View {
    let result: MCPResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "puzzlepiece")
                    .font(.system(size: 10))
                Text("\(MCPToolFormatter.toTitleCase(result.serverName)) - \(MCPToolFormatter.toTitleCase(result.toolName))")
                    .font(.system(size: 10, design: .monospaced))
            }
            .foregroundColor(.purple.opacity(0.7))

            ForEach(Array(result.rawResult.prefix(5)), id: \.key) { key, value in
                HStack(alignment: .top, spacing: 4) {
                    Text("\(key):")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                    Text("\(String(describing: value).prefix(100))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(2)
                }
            }
        }
    }
}

struct GenericResultContent: View {
    let result: GenericResult

    var body: some View {
        if let content = result.rawContent, !content.isEmpty {
            GenericTextContent(text: content)
        } else {
            Text("Completed")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))
        }
    }
}

struct GenericTextContent: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.white.opacity(0.5))
            .lineLimit(15)
    }
}
