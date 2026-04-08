import XCTest
@testable import Codex_Island

final class CodexConversationParserTests: XCTestCase {
    private let sessionId = "test-session"

    // 这里主要锁 transcript parser 的几类高风险输入：runtime info、plan follow-up、扁平/嵌套 event_msg 格式。
    func testRuntimeInfoParsesModelAndTokenUsage() async throws {
        let transcript = """
        {"timestamp":"2026-04-03T01:00:00Z","type":"session_meta","payload":{"model_provider":"openai"}}
        {"timestamp":"2026-04-03T01:00:01Z","type":"event_msg","payload":{"type":"task_started","payload":{"turn_id":"turn-1","model_context_window":950000}}}
        {"timestamp":"2026-04-03T01:00:02Z","type":"turn_context","payload":{"turn_id":"turn-1","model":"gpt-5.4","effort":"xhigh","collaboration_mode":{"mode":"default","settings":{"model":"gpt-5.4","reasoning_effort":"xhigh"}}}}
        {"timestamp":"2026-04-03T01:00:03Z","type":"event_msg","payload":{"type":"token_count","payload":{"info":{"total_token_usage":{"input_tokens":120000,"cached_input_tokens":10000,"output_tokens":5000,"reasoning_output_tokens":800,"total_tokens":125000},"last_token_usage":{"input_tokens":95000,"cached_input_tokens":5000,"output_tokens":5000,"reasoning_output_tokens":1000,"total_tokens":100000},"model_context_window":950000}}}}
        """

        let runtimeInfo = try await runtimeInfo(from: transcript)

        XCTAssertEqual(runtimeInfo.modelProvider, "openai")
        XCTAssertEqual(runtimeInfo.model, "gpt-5.4")
        XCTAssertEqual(runtimeInfo.reasoningEffort, "xhigh")
        XCTAssertEqual(runtimeInfo.tokenUsage?.modelContextWindow, 950000)
        XCTAssertEqual(runtimeInfo.tokenUsage?.totalTokenUsage.totalTokens, 125000)
        XCTAssertEqual(runtimeInfo.tokenUsage?.lastTokenUsage.totalTokens, 100000)
        XCTAssertEqual(runtimeInfo.tokenUsage?.contextRemainingPercent, 91)
    }

    // 旧格式的 request_user_input 走 response_item.function_call，这里保留多题 plan mode 样例。
    func testPendingUserInputParsesPlanOptions() async throws {
        let transcript = #"""
        {"timestamp":"2026-04-03T08:43:40Z","type":"event_msg","payload":{"type":"task_started","payload":{"turn_id":"turn-1","model_context_window":950000,"collaboration_mode_kind":"plan"}}}
        {"timestamp":"2026-04-03T08:43:50Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{\"questions\":[{\"header\":\"测试类型\",\"id\":\"test_type_round4\",\"question\":\"这轮你想验证哪种提问风格？\",\"options\":[{\"label\":\"常规澄清 (Recommended)\",\"description\":\"标准 Plan Mode 风格，问题直接、信息密度适中。\"},{\"label\":\"强约束决策\",\"description\":\"每题更偏实现取舍和边界锁定。\"},{\"label\":\"轻量确认\",\"description\":\"问题更短，适合快速点选。\"}]},{\"header\":\"选项布局\",\"id\":\"option_layout_round4\",\"question\":\"你这轮更想观察哪种选项组织方式？\",\"options\":[{\"label\":\"推荐项优先 (Recommended)\",\"description\":\"把默认建议放在第一位，最符合常规用法。\"},{\"label\":\"对立取舍\",\"description\":\"突出两三种互斥方案之间的差异。\"},{\"label\":\"结果导向\",\"description\":\"按后续动作来组织选项，而不是按主题。\"}]}]}","call_id":"call_plan_options"}}
        """#

        let interaction = try await firstUserInputInteraction(from: transcript)

        XCTAssertEqual(interaction.questions.count, 2)
        XCTAssertEqual(interaction.questions[0].header, "测试类型")
        XCTAssertEqual(interaction.questions[0].options.count, 3)
        XCTAssertEqual(interaction.questions[0].options[0].label, "常规澄清 (Recommended)")
        XCTAssertEqual(interaction.questions[1].header, "选项布局")
        XCTAssertEqual(interaction.questions[1].options[2].description, "按后续动作来组织选项，而不是按主题。")
    }

    // 新格式会把 follow-up 选项直接塞进 event_msg.request_user_input，这里锁住本地 plan 收尾入口。
    func testPendingUserInputParsesEventMsgPlanCompletionOptions() async throws {
        let transcript = #"""
        {"timestamp":"2026-04-03T08:43:40Z","type":"event_msg","payload":{"type":"task_started","payload":{"turn_id":"turn-1","model_context_window":950000,"collaboration_mode_kind":"plan"}}}
        {"timestamp":"2026-04-03T08:44:10Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"计划已整理完成，下面是建议执行方案。"}]}}
        {"timestamp":"2026-04-03T08:44:11Z","type":"event_msg","payload":{"type":"request_user_input","payload":{"call_id":"call_exit_plan_followup","turn_id":"turn-1","questions":[{"header":"下一步","id":"next_step","question":"要执行这份报告，还是继续留在 Plan 模式里提问？","options":[{"label":"执行这份报告 (Recommended)","description":"退出 Plan 模式并按这份方案继续。"},{"label":"继续在 Plan 模式提问","description":"保留当前 Plan 模式，继续补充澄清问题。"}]}]}}}
        """#

        let interaction = try await firstUserInputInteraction(from: transcript)

        assertPlanFollowupInteraction(
            interaction,
            id: "call_exit_plan_followup",
            header: "下一步",
            labels: [
                "执行这份报告 (Recommended)",
                "继续在 Plan 模式提问"
            ]
        )
        XCTAssertEqual(interaction.transport, .codexLocal(callId: "call_exit_plan_followup", turnId: "turn-1"))
    }

    // follow-up 选项不能在 turn/task complete 时被立刻清掉，要保留到下一次 task_started。
    func testPendingUserInputSurvivesTurnCompleteUntilNextTaskStarts() async throws {
        let transcript = #"""
        {"timestamp":"2026-04-03T08:43:40Z","type":"event_msg","payload":{"type":"task_started","payload":{"turn_id":"turn-1","model_context_window":950000,"collaboration_mode_kind":"plan"}}}
        {"timestamp":"2026-04-03T08:44:11Z","type":"event_msg","payload":{"type":"request_user_input","payload":{"call_id":"call_exit_plan_followup","turn_id":"turn-1","questions":[{"header":"下一步","id":"next_step","question":"要执行这份报告，还是继续留在 Plan 模式里提问？","options":[{"label":"执行这份报告 (Recommended)","description":"退出 Plan 模式并按这份方案继续。"},{"label":"继续在 Plan 模式提问","description":"保留当前 Plan 模式，继续补充澄清问题。"}]}]}}}
        {"timestamp":"2026-04-03T08:44:12Z","type":"event_msg","payload":{"type":"turn_complete","payload":{"turn_id":"turn-1"}}}
        {"timestamp":"2026-04-03T08:44:13Z","type":"event_msg","payload":{"type":"task_complete","payload":{"turn_id":"turn-1"}}}
        """#

        let interaction = try await firstUserInputInteraction(from: transcript)

        assertPlanFollowupInteraction(
            interaction,
            id: "call_exit_plan_followup",
            header: "下一步",
            labels: [
                "执行这份报告 (Recommended)",
                "继续在 Plan 模式提问"
            ]
        )
    }

    // 一旦新任务开始，旧 plan follow-up 必须被清空，避免 UI 继续显示过期选项。
    func testTaskStartedClearsPreviousPendingUserInput() async throws {
        let transcript = #"""
        {"timestamp":"2026-04-03T08:43:40Z","type":"event_msg","payload":{"type":"task_started","payload":{"turn_id":"turn-1","model_context_window":950000,"collaboration_mode_kind":"plan"}}}
        {"timestamp":"2026-04-03T08:44:11Z","type":"event_msg","payload":{"type":"request_user_input","payload":{"call_id":"call_exit_plan_followup","turn_id":"turn-1","questions":[{"header":"下一步","id":"next_step","question":"要执行这份报告，还是继续留在 Plan 模式里提问？","options":[{"label":"执行这份报告 (Recommended)","description":"退出 Plan 模式并按这份方案继续。"},{"label":"继续在 Plan 模式提问","description":"保留当前 Plan 模式，继续补充澄清问题。"}]}]}}}
        {"timestamp":"2026-04-03T08:44:14Z","type":"event_msg","payload":{"type":"task_started","payload":{"turn_id":"turn-2","model_context_window":950000,"collaboration_mode_kind":"default"}}}
        """#

        let interactions = try await pendingInteractions(from: transcript)

        XCTAssertTrue(interactions.isEmpty)
    }

    // 某些真实 transcript 只有 proposed_plan 文本和 task_complete；parser 需要合成二选一 follow-up。
    func testProposedPlanBlockSynthesizesFollowupInteraction() async throws {
        let transcript = #"""
        {"timestamp":"2026-04-03T09:17:29Z","type":"turn_context","payload":{"turn_id":"turn-1","collaboration_mode":{"mode":"plan","settings":{"model":"gpt-5.4","reasoning_effort":"high"}}}}
        {"timestamp":"2026-04-03T09:17:29Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1","model_context_window":950000,"collaboration_mode_kind":"plan"}}
        {"timestamp":"2026-04-03T09:17:30Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"<proposed_plan>\n# 平台化供应商密钥管理\n\n- 这里只是计划正文。\n</proposed_plan>"}]}}
        {"timestamp":"2026-04-03T09:17:31Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}
        """#

        let interaction = try await firstUserInputInteraction(from: transcript)
        let messages = try await parsedMessages(from: transcript)

        XCTAssertEqual(interaction.questions.first?.question, "Implement this plan?")
        XCTAssertEqual(interaction.questions.first?.options.map(\.label), [
            "Yes, implement this plan",
            "No, stay in Plan mode"
        ])
        XCTAssertFalse(messages.first?.textContent.contains("<proposed_plan>") ?? true)
        XCTAssertFalse(messages.first?.textContent.contains("</proposed_plan>") ?? true)
    }

    // 真实 rollout 里还见过扁平 event_msg 结构；这里防止 parser 只兼容旧的 payload.payload 嵌套格式。
    func testPendingUserInputParsesFlatEventMsgFormat() async throws {
        let transcript = #"""
        {"timestamp":"2026-04-03T08:43:40Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1","model_context_window":950000,"collaboration_mode_kind":"plan"}}
        {"timestamp":"2026-04-03T08:44:11Z","type":"event_msg","payload":{"type":"request_user_input","call_id":"call_exit_plan_followup","turn_id":"turn-1","questions":[{"header":"下一步","id":"next_step","question":"要执行这份报告，还是继续留在 Plan 模式里提问？","options":[{"label":"执行这份报告 (Recommended)","description":"退出 Plan 模式并按这份方案继续。"},{"label":"继续在 Plan 模式提问","description":"保留当前 Plan 模式，继续补充澄清问题。"}]}]}}
        """#

        let interaction = try await firstUserInputInteraction(from: transcript)

        XCTAssertEqual(interaction.id, "call_exit_plan_followup")
        XCTAssertEqual(interaction.questions.first?.question, "要执行这份报告，还是继续留在 Plan 模式里提问？")
    }

    func testMessageContentParsesImageAttachmentAndStripsImageTagsFromText() async throws {
        let transcript = #"""
        {"timestamp":"2026-04-08T06:00:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<image name=[Image #1]></image>\n请看这张图，[Image #1] 这里有问题。"},{"type":"input_image","image_url":"https://example.com/image.png","name":"debug screenshot"}]}}
        """#

        let messages = try await parsedMessages(from: transcript)
        let history = try await parsedHistory(from: transcript)

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].textContent, "请看这张图，这里有问题。")

        guard history.count == 2 else {
            return XCTFail("Expected text + image history items")
        }
        guard case .user(let text) = history[0].type else {
            return XCTFail("Expected first history item to be user text")
        }
        XCTAssertEqual(text, "请看这张图，这里有问题。")

        guard case .userImage(let attachment) = history[1].type else {
            return XCTFail("Expected second history item to be user image")
        }
        XCTAssertEqual(attachment.source, .remoteURL("https://example.com/image.png"))
        XCTAssertEqual(attachment.label, "debug screenshot")
    }

    // 每个用例都写独立 rollout.jsonl，尽量贴近真实 transcript 文件读取路径。
    private func makeTranscriptFile(contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("rollout.jsonl")
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return fileURL
    }

    private func runtimeInfo(from transcript: String) async throws -> SessionRuntimeInfo {
        let url = try makeTranscriptFile(contents: transcript)
        return await CodexConversationParser.shared.runtimeInfo(
            sessionId: sessionId,
            transcriptPath: url.path
        )
    }

    private func pendingInteractions(from transcript: String) async throws -> [PendingInteraction] {
        let url = try makeTranscriptFile(contents: transcript)
        return await CodexConversationParser.shared.pendingInteractions(
            sessionId: sessionId,
            transcriptPath: url.path
        )
    }

    private func firstUserInputInteraction(from transcript: String) async throws -> PendingUserInputInteraction {
        let interactions = try await pendingInteractions(from: transcript)
        guard case .userInput(let interaction)? = interactions.first else {
            XCTFail("Expected user input interaction")
            throw ParserTestError.missingUserInputInteraction
        }
        return interaction
    }

    private func parsedMessages(from transcript: String) async throws -> [ChatMessage] {
        let url = try makeTranscriptFile(contents: transcript)
        return await CodexConversationParser.shared.parseFullConversation(
            sessionId: sessionId,
            transcriptPath: url.path
        )
    }

    private func parsedHistory(from transcript: String) async throws -> [ChatHistoryItem] {
        let snapshot = await CodexConversationParser.shared.parseContent(
            sessionId: sessionId,
            content: transcript
        )
        return snapshot.history
    }

    private func assertPlanFollowupInteraction(
        _ interaction: PendingUserInputInteraction,
        id: String,
        header: String,
        labels: [String]
    ) {
        XCTAssertEqual(interaction.id, id)
        XCTAssertEqual(interaction.questions.count, 1)
        XCTAssertEqual(interaction.questions[0].header, header)
        XCTAssertEqual(interaction.questions[0].options.map(\.label), labels)
    }
}

private enum ParserTestError: Error {
    case missingUserInputInteraction
}
