import XCTest
@testable import Codex_Island

final class CodexConversationParserTests: XCTestCase {
    func testRuntimeInfoParsesModelAndTokenUsage() async throws {
        let transcript = """
        {"timestamp":"2026-04-03T01:00:00Z","type":"session_meta","payload":{"model_provider":"openai"}}
        {"timestamp":"2026-04-03T01:00:01Z","type":"event_msg","payload":{"type":"task_started","payload":{"turn_id":"turn-1","model_context_window":950000}}}
        {"timestamp":"2026-04-03T01:00:02Z","type":"turn_context","payload":{"turn_id":"turn-1","model":"gpt-5.4","effort":"xhigh","collaboration_mode":{"mode":"default","settings":{"model":"gpt-5.4","reasoning_effort":"xhigh"}}}}
        {"timestamp":"2026-04-03T01:00:03Z","type":"event_msg","payload":{"type":"token_count","payload":{"info":{"total_token_usage":{"input_tokens":120000,"cached_input_tokens":10000,"output_tokens":5000,"reasoning_output_tokens":800,"total_tokens":125000},"last_token_usage":{"input_tokens":95000,"cached_input_tokens":5000,"output_tokens":5000,"reasoning_output_tokens":1000,"total_tokens":100000},"model_context_window":950000}}}}
        """

        let url = try makeTranscriptFile(contents: transcript)

        let runtimeInfo = await CodexConversationParser.shared.runtimeInfo(
            sessionId: UUID().uuidString,
            transcriptPath: url.path
        )

        XCTAssertEqual(runtimeInfo.modelProvider, "openai")
        XCTAssertEqual(runtimeInfo.model, "gpt-5.4")
        XCTAssertEqual(runtimeInfo.reasoningEffort, "xhigh")
        XCTAssertEqual(runtimeInfo.tokenUsage?.modelContextWindow, 950000)
        XCTAssertEqual(runtimeInfo.tokenUsage?.totalTokenUsage.totalTokens, 125000)
        XCTAssertEqual(runtimeInfo.tokenUsage?.lastTokenUsage.totalTokens, 100000)
        XCTAssertEqual(runtimeInfo.tokenUsage?.contextRemainingPercent, 91)
    }

    func testPendingUserInputParsesPlanOptions() async throws {
        let transcript = #"""
        {"timestamp":"2026-04-03T08:43:40Z","type":"event_msg","payload":{"type":"task_started","payload":{"turn_id":"turn-1","model_context_window":950000,"collaboration_mode_kind":"plan"}}}
        {"timestamp":"2026-04-03T08:43:50Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{\"questions\":[{\"header\":\"测试类型\",\"id\":\"test_type_round4\",\"question\":\"这轮你想验证哪种提问风格？\",\"options\":[{\"label\":\"常规澄清 (Recommended)\",\"description\":\"标准 Plan Mode 风格，问题直接、信息密度适中。\"},{\"label\":\"强约束决策\",\"description\":\"每题更偏实现取舍和边界锁定。\"},{\"label\":\"轻量确认\",\"description\":\"问题更短，适合快速点选。\"}]},{\"header\":\"选项布局\",\"id\":\"option_layout_round4\",\"question\":\"你这轮更想观察哪种选项组织方式？\",\"options\":[{\"label\":\"推荐项优先 (Recommended)\",\"description\":\"把默认建议放在第一位，最符合常规用法。\"},{\"label\":\"对立取舍\",\"description\":\"突出两三种互斥方案之间的差异。\"},{\"label\":\"结果导向\",\"description\":\"按后续动作来组织选项，而不是按主题。\"}]}]}","call_id":"call_plan_options"}}
        """#

        let url = try makeTranscriptFile(contents: transcript)

        let interactions = await CodexConversationParser.shared.pendingInteractions(
            sessionId: UUID().uuidString,
            transcriptPath: url.path
        )

        guard case .userInput(let interaction)? = interactions.first else {
            return XCTFail("Expected user input interaction")
        }

        XCTAssertEqual(interaction.questions.count, 2)
        XCTAssertEqual(interaction.questions[0].header, "测试类型")
        XCTAssertEqual(interaction.questions[0].options.count, 3)
        XCTAssertEqual(interaction.questions[0].options[0].label, "常规澄清 (Recommended)")
        XCTAssertEqual(interaction.questions[1].header, "选项布局")
        XCTAssertEqual(interaction.questions[1].options[2].description, "按后续动作来组织选项，而不是按主题。")
    }

    func testPendingUserInputParsesEventMsgPlanCompletionOptions() async throws {
        let transcript = #"""
        {"timestamp":"2026-04-03T08:43:40Z","type":"event_msg","payload":{"type":"task_started","payload":{"turn_id":"turn-1","model_context_window":950000,"collaboration_mode_kind":"plan"}}}
        {"timestamp":"2026-04-03T08:44:10Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"计划已整理完成，下面是建议执行方案。"}]}}
        {"timestamp":"2026-04-03T08:44:11Z","type":"event_msg","payload":{"type":"request_user_input","payload":{"call_id":"call_exit_plan_followup","turn_id":"turn-1","questions":[{"header":"下一步","id":"next_step","question":"要执行这份报告，还是继续留在 Plan 模式里提问？","options":[{"label":"执行这份报告 (Recommended)","description":"退出 Plan 模式并按这份方案继续。"},{"label":"继续在 Plan 模式提问","description":"保留当前 Plan 模式，继续补充澄清问题。"}]}]}}}
        """#

        let url = try makeTranscriptFile(contents: transcript)

        let interactions = await CodexConversationParser.shared.pendingInteractions(
            sessionId: UUID().uuidString,
            transcriptPath: url.path
        )

        guard case .userInput(let interaction)? = interactions.first else {
            return XCTFail("Expected user input interaction")
        }

        XCTAssertEqual(interaction.id, "call_exit_plan_followup")
        XCTAssertEqual(interaction.questions.count, 1)
        XCTAssertEqual(interaction.questions[0].header, "下一步")
        XCTAssertEqual(interaction.questions[0].options.map(\.label), [
            "执行这份报告 (Recommended)",
            "继续在 Plan 模式提问"
        ])
        XCTAssertEqual(interaction.transport, .codexLocal(callId: "call_exit_plan_followup", turnId: "turn-1"))
    }

    func testPendingUserInputSurvivesTurnCompleteUntilNextTaskStarts() async throws {
        let transcript = #"""
        {"timestamp":"2026-04-03T08:43:40Z","type":"event_msg","payload":{"type":"task_started","payload":{"turn_id":"turn-1","model_context_window":950000,"collaboration_mode_kind":"plan"}}}
        {"timestamp":"2026-04-03T08:44:11Z","type":"event_msg","payload":{"type":"request_user_input","payload":{"call_id":"call_exit_plan_followup","turn_id":"turn-1","questions":[{"header":"下一步","id":"next_step","question":"要执行这份报告，还是继续留在 Plan 模式里提问？","options":[{"label":"执行这份报告 (Recommended)","description":"退出 Plan 模式并按这份方案继续。"},{"label":"继续在 Plan 模式提问","description":"保留当前 Plan 模式，继续补充澄清问题。"}]}]}}}
        {"timestamp":"2026-04-03T08:44:12Z","type":"event_msg","payload":{"type":"turn_complete","payload":{"turn_id":"turn-1"}}}
        {"timestamp":"2026-04-03T08:44:13Z","type":"event_msg","payload":{"type":"task_complete","payload":{"turn_id":"turn-1"}}}
        """#

        let url = try makeTranscriptFile(contents: transcript)

        let interactions = await CodexConversationParser.shared.pendingInteractions(
            sessionId: UUID().uuidString,
            transcriptPath: url.path
        )

        guard case .userInput(let interaction)? = interactions.first else {
            return XCTFail("Expected user input interaction")
        }

        XCTAssertEqual(interaction.id, "call_exit_plan_followup")
        XCTAssertEqual(interaction.questions.count, 1)
    }

    func testTaskStartedClearsPreviousPendingUserInput() async throws {
        let transcript = #"""
        {"timestamp":"2026-04-03T08:43:40Z","type":"event_msg","payload":{"type":"task_started","payload":{"turn_id":"turn-1","model_context_window":950000,"collaboration_mode_kind":"plan"}}}
        {"timestamp":"2026-04-03T08:44:11Z","type":"event_msg","payload":{"type":"request_user_input","payload":{"call_id":"call_exit_plan_followup","turn_id":"turn-1","questions":[{"header":"下一步","id":"next_step","question":"要执行这份报告，还是继续留在 Plan 模式里提问？","options":[{"label":"执行这份报告 (Recommended)","description":"退出 Plan 模式并按这份方案继续。"},{"label":"继续在 Plan 模式提问","description":"保留当前 Plan 模式，继续补充澄清问题。"}]}]}}}
        {"timestamp":"2026-04-03T08:44:14Z","type":"event_msg","payload":{"type":"task_started","payload":{"turn_id":"turn-2","model_context_window":950000,"collaboration_mode_kind":"default"}}}
        """#

        let url = try makeTranscriptFile(contents: transcript)

        let interactions = await CodexConversationParser.shared.pendingInteractions(
            sessionId: UUID().uuidString,
            transcriptPath: url.path
        )

        XCTAssertTrue(interactions.isEmpty)
    }

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
}
