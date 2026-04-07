//
//  ToolResultViews.swift
//  CodexIsland
//
//  Dispatcher for structured tool result rendering.
//

import SwiftUI

struct ToolResultContent: View {
    let tool: ToolCallItem

    var body: some View {
        if let structured = tool.structuredResult {
            switch structured {
            case .read(let result):
                ReadResultContent(result: result)
            case .edit(let result):
                EditResultContent(result: result, toolInput: tool.input)
            case .write(let result):
                WriteResultContent(result: result)
            case .bash(let result):
                BashResultContent(result: result)
            case .grep(let result):
                GrepResultContent(result: result)
            case .glob(let result):
                GlobResultContent(result: result)
            case .todoWrite(let result):
                TodoWriteResultContent(result: result)
            case .task(let result):
                TaskResultContent(result: result)
            case .webFetch(let result):
                WebFetchResultContent(result: result)
            case .webSearch(let result):
                WebSearchResultContent(result: result)
            case .askUserQuestion(let result):
                AskUserQuestionResultContent(result: result)
            case .bashOutput(let result):
                BashOutputResultContent(result: result)
            case .killShell(let result):
                KillShellResultContent(result: result)
            case .exitPlanMode(let result):
                ExitPlanModeResultContent(result: result)
            case .mcp(let result):
                MCPResultContent(result: result)
            case .generic(let result):
                GenericResultContent(result: result)
            }
        } else if tool.name == "Edit" {
            EditInputDiffView(input: tool.input)
        } else if let result = tool.result {
            GenericTextContent(text: result)
        } else {
            EmptyView()
        }
    }
}
