import XCTest
@testable import Codex_Island

final class PendingInteractionTests: XCTestCase {
    // 这里主要覆盖本地 transcript、local app-server thread 与 UI pending interaction 展示之间的优先级和回退规则。
    override func setUp() async throws {
        try await super.setUp()
        await resetSessionStore()
        await MainActor.run {
            ChatHistoryManager.shared.resetForTesting()
            TestObjectRetainer.reset()
        }
    }

    override func tearDown() async throws {
        await resetSessionStore()
        await MainActor.run {
            ChatHistoryManager.shared.resetForTesting()
            TestObjectRetainer.reset()
        }
        try await super.tearDown()
    }

    // 先固定纯展示规则：能 inline、只能只读、以及完全退回终端三种 presentation mode。
    func testPresentationModeUsesInlineWhenQuestionsCanBeAnsweredInline() {
        let interaction = makeInteraction(questions: [
            PendingInteractionQuestion(
                id: "theme",
                header: "主题方向",
                question: "这次你想让我用哪类主题来触发选项？",
                options: [
                    PendingInteractionOption(label: "通用需求 (Recommended)", description: "中性场景。")
                ],
                isOther: false,
                isSecret: false
            )
        ])

        XCTAssertEqual(interaction.presentationMode(canRespondInline: true), .inline)
    }

    func testPresentationModeFallsBackToReadOnlyWhenInlineUnavailable() {
        let interaction = makeInteraction(questions: [
            PendingInteractionQuestion(
                id: "theme",
                header: "主题方向",
                question: "这次你想让我用哪类主题来触发选项？",
                options: [
                    PendingInteractionOption(label: "通用需求 (Recommended)", description: "中性场景。")
                ],
                isOther: false,
                isSecret: false
            )
        ])

        XCTAssertEqual(interaction.presentationMode(canRespondInline: false), .readOnly)
    }

    func testPresentationModeUsesTerminalOnlyWhenQuestionListIsEmpty() {
        let interaction = makeInteraction(questions: [])

        XCTAssertEqual(interaction.presentationMode(canRespondInline: true), .terminalOnly)
        XCTAssertEqual(interaction.presentationMode(canRespondInline: false), .terminalOnly)
    }

    @MainActor
    func testLocalAppServerPendingInteractionOverridesTranscriptInteraction() async throws {
        let harness = makeLocalAppServerHarness()

        harness.localMonitor.startMonitoring()
        await SessionStore.shared.process(.hookReceived(makeHookEvent(sessionId: "session-1")))
        await Task.yield()

        harness.localMonitor.apply(event: .threadUpsert(
            hostId: harness.host.id,
            thread: makeThread(id: "session-1", status: .idle)
        ))
        harness.localMonitor.apply(event: .userInputRequest(
            hostId: harness.host.id,
            threadId: "session-1",
            interaction: PendingUserInputInteraction(
                id: "remote-request",
                title: "Codex needs your input",
                questions: [
                    PendingInteractionQuestion(
                        id: "scope",
                        header: "Scope",
                        question: "Choose one",
                        options: [PendingInteractionOption(label: "One", description: nil)],
                        isOther: false,
                        isSecret: false
                    )
                ],
                transport: .remoteAppServer(requestId: .int(7))
            )
        ))
        await Task.yield()

        let session = try XCTUnwrap(harness.sessionMonitor.instances.first(where: { $0.sessionId == "session-1" }))
        XCTAssertEqual(harness.sessionMonitor.pendingInteraction(for: session)?.id, "remote-request")
        XCTAssertEqual(session.pendingInteractions.first?.id, "remote-request")
        XCTAssertTrue(session.needsAttention)
    }

    @MainActor
    func testLocalApprovalResponseReturnsFailureWhenAppServerRespondFails() async throws {
        let harness = makeLocalAppServerHarness()

        harness.connection.respondActionHandler = { _, _ in
            throw RemoteSessionError.transport("approval response failed")
        }

        harness.localMonitor.startMonitoring()
        await SessionStore.shared.process(.hookReceived(makeHookEvent(sessionId: "session-1")))
        await Task.yield()

        harness.localMonitor.apply(event: .threadUpsert(
            hostId: harness.host.id,
            thread: makeThread(
                id: "session-1",
                status: .active(activeFlags: [.waitingOnUserInput])
            )
        ))
        harness.localMonitor.apply(event: .approval(
            hostId: harness.host.id,
            threadId: "session-1",
            approval: RemotePendingApproval(
                id: "approval-1",
                requestId: .int(1),
                kind: .commandExecution,
                itemId: "item-1",
                threadId: "session-1",
                turnId: "turn-1",
                title: "Command Execution",
                detail: "pwd",
                requestedPermissions: .none,
                availableActions: [.allow, .deny]
            )
        ))
        await Task.yield()

        let result = await harness.sessionMonitor.respond(sessionId: "session-1", action: .allow)

        XCTAssertEqual(result, .failed("approval response failed"))
    }

    @MainActor
    func testLocalApprovalResponseReturnsInitializingWhileThreadLoadPending() async throws {
        let harness = makeLocalAppServerHarness()

        harness.connection.refreshThreadsHandler = {
            try await Task.sleep(for: .milliseconds(400))
        }
        harness.connection.resumeThreadHandler = { threadId, _ in
            makeThreadResumeResponse(thread: makeThread(id: threadId, preview: "Recovered", cwd: "/tmp/project"))
        }

        harness.localMonitor.startMonitoring()
        await SessionStore.shared.process(.hookReceived(makeHookEvent(
            sessionId: "session-1",
            transcriptPath: "/Users/test/.codex/sessions/2026/04/03/rollout-2026-04-03T14-40-04-session-1.jsonl",
            cwd: "/tmp/project"
        )))
        await Task.yield()

        await SessionStore.shared.process(.fileUpdated(FileUpdatePayload(
            sessionId: "session-1",
            cwd: "/tmp/project",
            messages: [],
            isIncremental: true,
            completedToolIds: [],
            toolResults: [:],
            structuredResults: [:],
            pendingInteractions: [
                .approval(PendingApprovalInteraction(
                    id: "approval-1",
                    title: "Command Execution",
                    kind: .commandExecution,
                    detail: "pwd",
                    requestedPermissions: .none,
                    availableActions: [.allow, .deny],
                    transport: .remoteAppServer(requestId: .int(1))
                ))
            ],
            transcriptPhase: .waitingForInput
        )))
        await Task.yield()

        async let firstAttempt = harness.sessionMonitor.sendMessageResult(sessionId: "session-1", text: "prime load")
        try? await Task.sleep(for: .milliseconds(50))
        let approvalResult = await harness.sessionMonitor.respond(sessionId: "session-1", action: .allow)
        _ = await firstAttempt

        XCTAssertEqual(approvalResult, .initializing)
    }

    // 如果本地还没绑上 app-server thread，transcript 里的 pending interaction 也必须能展示和回退。
    @MainActor
    func testLocalHookSessionStaysIdleUntilAppServerThreadBinds() async throws {
        let harness = makeLocalAppServerHarness()

        harness.localMonitor.startMonitoring()
        await SessionStore.shared.process(.hookReceived(makeHookEvent(sessionId: "session-1")))
        await Task.yield()

        let session = try XCTUnwrap(harness.sessionMonitor.instances.first(where: { $0.sessionId == "session-1" }))
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(harness.sessionMonitor.pendingInteraction(for: session))
        XCTAssertFalse(harness.sessionMonitor.canSendMessage(to: session))
    }

    @MainActor
    func testLocalTranscriptPendingInteractionIsShownWithoutAppServerThread() async throws {
        let harness = makeLocalAppServerHarness()

        harness.localMonitor.startMonitoring()
        await SessionStore.shared.process(.hookReceived(makeHookEvent(sessionId: "session-1")))
        await Task.yield()

        await SessionStore.shared.process(.fileUpdated(FileUpdatePayload(
            sessionId: "session-1",
            cwd: "/tmp/project",
            messages: [],
            isIncremental: true,
            completedToolIds: [],
            toolResults: [:],
            structuredResults: [:],
            pendingInteractions: [
                .userInput(PendingUserInputInteraction(
                    id: "local-transcript-request",
                    title: "Codex needs your input",
                    questions: [
                        PendingInteractionQuestion(
                            id: "next_step",
                            header: "下一步",
                            question: "继续还是执行？",
                            options: [
                                PendingInteractionOption(label: "执行", description: nil),
                                PendingInteractionOption(label: "继续", description: nil)
                            ],
                            isOther: false,
                            isSecret: false
                        )
                    ],
                    transport: .codexLocal(callId: "local-transcript-request", turnId: "turn-1")
                ))
            ],
            transcriptPhase: .waitingForInput
        )))
        await Task.yield()

        let session = try XCTUnwrap(harness.sessionMonitor.instances.first(where: { $0.sessionId == "session-1" }))
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(session.pendingInteractions.first?.id, "local-transcript-request")
        XCTAssertEqual(harness.sessionMonitor.pendingInteraction(for: session)?.id, "local-transcript-request")
        XCTAssertFalse(harness.sessionMonitor.canSendMessage(to: session))
        XCTAssertFalse(
            harness.sessionMonitor.canRespondInline(
                to: session,
                interaction: try XCTUnwrap(harness.sessionMonitor.pendingInteraction(for: session))
            )
        )
    }

    @MainActor
    func testLocalTranscriptPendingInteractionUsesInlineFallbackWhenAppServerThreadHasNoInteraction() async throws {
        let harness = makeLocalAppServerHarness()

        harness.localMonitor.startMonitoring()
        await SessionStore.shared.process(.hookReceived(makeHookEvent(sessionId: "session-1")))
        await Task.yield()

        harness.localMonitor.apply(event: .threadUpsert(
            hostId: harness.host.id,
            thread: makeThread(id: "session-1", status: .idle)
        ))
        await SessionStore.shared.process(.fileUpdated(FileUpdatePayload(
            sessionId: "session-1",
            cwd: "/tmp/project",
            messages: [],
            isIncremental: true,
            completedToolIds: [],
            toolResults: [:],
            structuredResults: [:],
            pendingInteractions: [
                .userInput(PendingUserInputInteraction(
                    id: "local-transcript-request",
                    title: "Codex needs your input",
                    questions: [
                        PendingInteractionQuestion(
                            id: "next_step",
                            header: "下一步",
                            question: "继续还是执行？",
                            options: [
                                PendingInteractionOption(label: "执行", description: nil),
                                PendingInteractionOption(label: "继续", description: nil)
                            ],
                            isOther: false,
                            isSecret: false
                        )
                    ],
                    transport: .codexLocal(callId: "local-transcript-request", turnId: "turn-1")
                ))
            ],
            transcriptPhase: .waitingForInput
        )))
        await Task.yield()

        let session = try XCTUnwrap(harness.sessionMonitor.instances.first(where: { $0.sessionId == "session-1" }))
        XCTAssertEqual(session.pendingInteractions.first?.id, "local-transcript-request")
        XCTAssertEqual(harness.sessionMonitor.pendingInteraction(for: session)?.id, "local-transcript-request")
        XCTAssertTrue(
            harness.sessionMonitor.canRespondInline(
                to: session,
                interaction: try XCTUnwrap(harness.sessionMonitor.pendingInteraction(for: session))
            )
        )
    }

    @MainActor
    func testLocalTranscriptPendingInteractionCanRespondInlineViaAppServerThread() async throws {
        let sentText = LockedBox<String?>(nil)
        let harness = makeLocalAppServerHarness()

        harness.connection.sendMessageHandler = { _, text, _, _ in
            await sentText.set(text)
        }

        harness.localMonitor.startMonitoring()
        await SessionStore.shared.process(.hookReceived(makeHookEvent(sessionId: "session-1")))
        await Task.yield()

        harness.localMonitor.apply(event: .threadUpsert(
            hostId: harness.host.id,
            thread: makeThread(id: "session-1", status: .idle)
        ))
        await SessionStore.shared.process(.fileUpdated(FileUpdatePayload(
            sessionId: "session-1",
            cwd: "/tmp/project",
            messages: [],
            isIncremental: true,
            completedToolIds: [],
            toolResults: [:],
            structuredResults: [:],
            pendingInteractions: [
                .userInput(PendingUserInputInteraction(
                    id: "local-transcript-request",
                    title: "Codex needs your input",
                    questions: [
                        PendingInteractionQuestion(
                            id: "next_step",
                            header: "Next step",
                            question: "Implement this plan?",
                            options: [
                                PendingInteractionOption(label: "Yes, implement this plan (Recommended)", description: nil),
                                PendingInteractionOption(label: "No, stay in Plan mode", description: nil)
                            ],
                            isOther: false,
                            isSecret: false
                        )
                    ],
                    transport: .codexLocal(callId: "local-transcript-request", turnId: "turn-1")
                ))
            ],
            transcriptPhase: .waitingForInput
        )))
        await Task.yield()

        let session = try XCTUnwrap(harness.sessionMonitor.instances.first(where: { $0.sessionId == "session-1" }))
        let interaction = try XCTUnwrap(harness.sessionMonitor.pendingInteraction(for: session))
        XCTAssertTrue(harness.sessionMonitor.canRespondInline(to: session, interaction: interaction))

        let success = await harness.sessionMonitor.respond(
            sessionId: session.sessionId,
            answers: PendingInteractionAnswerPayload(
                answers: ["next_step": ["Yes, implement this plan (Recommended)"]]
            )
        )

        XCTAssertTrue(success)
        let capturedText = await sentText.get()
        XCTAssertEqual(capturedText, "Yes, implement this plan")
    }

    // 本地发送链路现在优先走 app-server；这些测试锁住 visible thread、hidden raw thread 和错误语义。
    @MainActor
    func testLocalSendMessageUsesAppServerThreadWhenAvailable() async throws {
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(
            id: "local-app-server",
            name: "Local App Server",
            sshTarget: "local-app-server",
            defaultCwd: "",
            isEnabled: true
        )
        let localMonitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: TestDiagnosticsLogger(),
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(localMonitor)

        let sentThreadId = LockedBox<String?>(nil)
        let sentText = LockedBox<String?>(nil)
        connection.sendMessageHandler = { threadId, text, _, _ in
            await sentThreadId.set(threadId)
            await sentText.set(text)
        }

        let sessionMonitor = CodexSessionMonitor(localAppServerMonitor: localMonitor)
        TestObjectRetainer.retain(sessionMonitor)

        localMonitor.startMonitoring()
        await SessionStore.shared.process(.hookReceived(makeHookEvent(sessionId: "session-1")))
        await Task.yield()

        localMonitor.apply(event: .threadUpsert(
            hostId: host.id,
            thread: makeThread(id: "session-1", status: .idle)
        ))
        await Task.yield()

        let success = await sessionMonitor.sendMessage(sessionId: "session-1", text: "hello app-server")
        let capturedThreadId = await sentThreadId.get()
        let capturedText = await sentText.get()
        XCTAssertTrue(success)
        XCTAssertEqual(capturedThreadId, "session-1")
        XCTAssertEqual(capturedText, "hello app-server")
    }

    @MainActor
    func testLocalSendMessageCanUseHiddenRawThreadForSameCwdSession() async throws {
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(
            id: "local-app-server",
            name: "Local App Server",
            sshTarget: "local-app-server",
            defaultCwd: "",
            isEnabled: true
        )
        let localMonitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: TestDiagnosticsLogger(),
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(localMonitor)

        let sentThreadId = LockedBox<String?>(nil)
        connection.sendMessageHandler = { threadId, _, _, _ in
            await sentThreadId.set(threadId)
        }

        let sessionMonitor = CodexSessionMonitor(localAppServerMonitor: localMonitor)
        TestObjectRetainer.retain(sessionMonitor)

        localMonitor.startMonitoring()
        let hiddenThreadId = "session-hidden"
        let transcriptPath = "/Users/test/.codex/sessions/2026/04/03/rollout-2026-04-03T14-40-04-\(hiddenThreadId).jsonl"
        await SessionStore.shared.process(.hookReceived(makeHookEvent(
            sessionId: hiddenThreadId,
            transcriptPath: transcriptPath,
            cwd: "/tmp/project"
        )))
        await Task.yield()

        localMonitor.apply(event: .threadList(
            hostId: host.id,
            threads: [
                makeThread(id: "session-visible", preview: "Newer", cwd: "/tmp/project"),
                makeThread(id: hiddenThreadId, preview: "Older", cwd: "/tmp/project")
            ]
        ))
        await Task.yield()

        let success = await sessionMonitor.sendMessage(sessionId: hiddenThreadId, text: "use raw thread")
        let capturedThreadId = await sentThreadId.get()

        XCTAssertTrue(success)
        XCTAssertEqual(capturedThreadId, hiddenThreadId)
    }

    @MainActor
    func testLocalSendMessageResultReturnsInitializingWhenThreadLoadAlreadyPending() async throws {
        let harness = makeLocalAppServerHarness()

        harness.connection.refreshThreadsHandler = {
            try await Task.sleep(for: .milliseconds(400))
        }
        harness.connection.resumeThreadHandler = { threadId, _ in
            makeThreadResumeResponse(thread: makeThread(id: threadId, preview: "Recovered", cwd: "/tmp"))
        }

        harness.localMonitor.startMonitoring()
        await SessionStore.shared.process(.hookReceived(makeHookEvent(sessionId: "session-1")))
        await Task.yield()

        async let firstAttempt = harness.sessionMonitor.sendMessageResult(sessionId: "session-1", text: "first")
        try? await Task.sleep(for: .milliseconds(50))
        let secondAttempt = await harness.sessionMonitor.sendMessageResult(sessionId: "session-1", text: "second")
        _ = await firstAttempt

        XCTAssertEqual(secondAttempt, .initializing)
    }

    @MainActor
    func testLocalSendMessageResultReturnsUnderlyingThreadLoadFailure() async throws {
        let harness = makeLocalAppServerHarness()

        harness.connection.refreshThreadsHandler = {
            throw RemoteSessionError.transport("app-server handshake failed")
        }
        harness.connection.resumeThreadHandler = { _, _ in
            throw RemoteSessionError.transport("thread resume failed")
        }

        harness.localMonitor.startMonitoring()
        await SessionStore.shared.process(.hookReceived(makeHookEvent(sessionId: "session-1")))
        await Task.yield()

        let result = await harness.sessionMonitor.sendMessageResult(sessionId: "session-1", text: "hello")

        XCTAssertEqual(result, .failed("app-server handshake failed"))
    }

    @MainActor
    func testLocalListModelsUsesAppServerConnection() async throws {
        let harness = makeLocalAppServerHarness()
        let includeHiddenFlag = LockedBox<Bool?>(nil)
        harness.connection.listModelsHandler = { includeHidden in
            await includeHiddenFlag.set(includeHidden)
            return [
                RemoteAppServerModel(
                    id: "gpt-5.4",
                    model: "gpt-5.4",
                    displayName: "GPT-5.4",
                    description: "Flagship",
                    hidden: false,
                    supportedReasoningEfforts: [
                        RemoteAppServerReasoningEffortOption(
                            reasoningEffort: .medium,
                            description: "Balanced"
                        )
                    ],
                    defaultReasoningEffort: .medium,
                    isDefault: true
                )
            ]
        }

        harness.localMonitor.startMonitoring()
        await SessionStore.shared.process(.hookReceived(makeHookEvent(sessionId: "session-1")))
        await Task.yield()

        harness.localMonitor.apply(event: .threadUpsert(
            hostId: harness.host.id,
            thread: makeThread(id: "session-1", status: .idle)
        ))
        await Task.yield()

        let models = try await harness.sessionMonitor.listLocalModels(sessionId: "session-1", includeHidden: true)
        let capturedIncludeHidden = await includeHiddenFlag.get()

        XCTAssertEqual(capturedIncludeHidden, true)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.model, "gpt-5.4")
    }

    @MainActor
    func testLocalSetTurnContextUsesAppServerThread() async throws {
        let harness = makeLocalAppServerHarness()
        let capturedContext = LockedBox<RemoteThreadTurnContext?>(nil)
        harness.connection.resumeThreadHandler = { threadId, turnContext in
            XCTAssertEqual(threadId, "session-1")
            await capturedContext.set(turnContext)
            return await makeThreadResumeResponse(
                thread: makeThread(id: "session-1", status: .idle),
                model: turnContext?.model ?? "gpt-5.4",
                approvalPolicy: turnContext?.approvalPolicy ?? .onRequest,
                approvalsReviewer: turnContext?.approvalsReviewer ?? .user,
                sandbox: turnContext?.sandboxPolicy ?? .workspaceWrite(),
                reasoningEffort: turnContext?.reasoningEffort ?? .high
            )
        }

        harness.localMonitor.startMonitoring()
        await SessionStore.shared.process(.hookReceived(makeHookEvent(sessionId: "session-1")))
        await Task.yield()

        harness.localMonitor.apply(event: .threadUpsert(
            hostId: harness.host.id,
            thread: makeThread(id: "session-1", status: .idle)
        ))
        await Task.yield()

        let desiredContext = RemoteThreadTurnContext(
            model: "gpt-5.5",
            reasoningEffort: .high,
            approvalPolicy: .never,
            approvalsReviewer: .user,
            sandboxPolicy: .dangerFullAccess,
            serviceTier: nil,
            collaborationMode: RemoteAppServerCollaborationMode(
                mode: .plan,
                settings: RemoteAppServerCollaborationSettings(
                    developerInstructions: nil,
                    model: "gpt-5.5",
                    reasoningEffort: .high
                )
            )
        )

        let updatedThread = try await harness.sessionMonitor.setLocalTurnContext(
            sessionId: "session-1",
            turnContext: desiredContext,
            synchronizeThread: true
        )
        let observedContext = await capturedContext.get()

        XCTAssertEqual(observedContext, desiredContext)
        XCTAssertEqual(updatedThread.currentModel, "gpt-5.5")
        XCTAssertEqual(updatedThread.turnContext.approvalPolicy, .never)
        XCTAssertEqual(updatedThread.turnContext.sandboxPolicy, .dangerFullAccess)
        XCTAssertEqual(updatedThread.turnContext.collaborationMode?.mode, .plan)
    }

    @MainActor
    func testLocalListCollaborationModesUsesAppServerConnection() async throws {
        let harness = makeLocalAppServerHarness()

        harness.connection.listCollaborationModesHandler = {
            [
                RemoteAppServerCollaborationModeMask(
                    name: "Default",
                    mode: .default,
                    model: "gpt-5.4",
                    reasoningEffort: .medium
                ),
                RemoteAppServerCollaborationModeMask(
                    name: "Plan",
                    mode: .plan,
                    model: "gpt-5.4",
                    reasoningEffort: .high
                )
            ]
        }

        harness.localMonitor.startMonitoring()
        await SessionStore.shared.process(.hookReceived(makeHookEvent(sessionId: "session-1")))
        await Task.yield()

        harness.localMonitor.apply(event: .threadUpsert(
            hostId: harness.host.id,
            thread: makeThread(id: "session-1", status: .idle)
        ))
        await Task.yield()

        let modes = try await harness.sessionMonitor.listLocalCollaborationModes(sessionId: "session-1")

        XCTAssertEqual(modes.count, 2)
        XCTAssertEqual(modes.last?.mode, .plan)
        XCTAssertEqual(modes.last?.reasoningEffort, .high)
    }

    // 即使只有 app-server 可见线程，也要合成为 synthetic local session，并进入统一历史/归档流程。
    @MainActor
    func testLocalSessionSummaryPrefersAppServerHistory() async throws {
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(
            id: "local-app-server",
            name: "Local App Server",
            sshTarget: "local-app-server",
            defaultCwd: "",
            isEnabled: true
        )
        let localMonitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: TestDiagnosticsLogger(),
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(localMonitor)

        let sessionMonitor = CodexSessionMonitor(localAppServerMonitor: localMonitor)
        TestObjectRetainer.retain(sessionMonitor)

        localMonitor.startMonitoring()
        await SessionStore.shared.process(.hookReceived(makeHookEvent(sessionId: "session-1")))
        await Task.yield()

        let historyThread = makeThread(
            id: "session-1",
            status: .idle,
            turns: [
                makeTurn(
                    items: [
                        .userMessage(id: "user-1", content: [.text("hello from app server")]),
                        .agentMessage(id: "assistant-1", text: "app server reply")
                    ],
                    status: .completed
                )
            ]
        )

        localMonitor.apply(event: .threadUpsert(hostId: host.id, thread: historyThread))
        await Task.yield()

        guard let session = sessionMonitor.instances.first(where: { $0.sessionId == "session-1" }) else {
            return XCTFail("Expected local session")
        }

        XCTAssertEqual(session.lastMessage, "app server reply")
        XCTAssertEqual(session.lastMessageRole, "assistant")
        XCTAssertEqual(session.firstUserMessage, "hello from app server")
        XCTAssertEqual(session.chatItems.count, 2)
    }

    @MainActor
    func testLocalPreferredHistoryComesFromAppServerThread() async throws {
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(
            id: "local-app-server",
            name: "Local App Server",
            sshTarget: "local-app-server",
            defaultCwd: "",
            isEnabled: true
        )
        let localMonitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: TestDiagnosticsLogger(),
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(localMonitor)

        let sessionMonitor = CodexSessionMonitor(localAppServerMonitor: localMonitor)
        TestObjectRetainer.retain(sessionMonitor)

        localMonitor.startMonitoring()
        await SessionStore.shared.process(.hookReceived(makeHookEvent(sessionId: "session-1")))
        await Task.yield()

        let historyThread = makeThread(
            id: "session-1",
            status: .idle,
            turns: [
                makeTurn(
                    items: [
                        .userMessage(id: "user-1", content: [.text("pick app-server history")]),
                        .agentMessage(id: "assistant-1", text: "history ready")
                    ],
                    status: .completed
                )
            ]
        )

        localMonitor.apply(event: .threadUpsert(hostId: host.id, thread: historyThread))
        await Task.yield()

        guard let session = sessionMonitor.instances.first(where: { $0.sessionId == "session-1" }) else {
            return XCTFail("Expected local session")
        }

        let preferredHistory = sessionMonitor.preferredHistory(for: session)

        XCTAssertTrue(sessionMonitor.prefersAppServerHistory(for: session))
        XCTAssertEqual(preferredHistory?.count, 2)
        guard case .assistant(let reply)? = preferredHistory?.last?.type else {
            return XCTFail("Expected assistant reply from app-server history")
        }
        XCTAssertEqual(reply, "history ready")
    }

    @MainActor
    func testLocalAppServerOnlyThreadAppearsAsSyntheticSessionAndCanSendMessage() async throws {
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(
            id: "local-app-server",
            name: "Local App Server",
            sshTarget: "local-app-server",
            defaultCwd: "",
            isEnabled: true
        )
        let localMonitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: TestDiagnosticsLogger(),
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(localMonitor)

        let sentThreadId = LockedBox<String?>(nil)
        let sentText = LockedBox<String?>(nil)
        connection.sendMessageHandler = { threadId, text, _, _ in
            await sentThreadId.set(threadId)
            await sentText.set(text)
        }

        let sessionMonitor = CodexSessionMonitor(localAppServerMonitor: localMonitor)
        TestObjectRetainer.retain(sessionMonitor)

        localMonitor.startMonitoring()
        localMonitor.apply(event: .threadUpsert(
            hostId: host.id,
            thread: makeThread(
                id: "app-thread-1",
                preview: "Synthetic Local Session",
                status: .idle,
                turns: [
                    makeTurn(
                        items: [.agentMessage(id: "assistant-1", text: "hello from synthetic thread")],
                        status: .completed
                    )
                ],
                cwd: "/tmp/synthetic-project"
            )
        ))
        await Task.yield()

        guard let syntheticSession = sessionMonitor.instances.first(where: { $0.sessionId == "app-thread-1" }) else {
            return XCTFail("Expected synthetic local session")
        }

        XCTAssertEqual(syntheticSession.provider, .codex)
        XCTAssertEqual(syntheticSession.displayTitle, "Synthetic Local Session")
        XCTAssertEqual(syntheticSession.lastMessage, "hello from synthetic thread")
        XCTAssertFalse(syntheticSession.canAttemptFocusTerminal)

        let success = await sessionMonitor.sendMessage(sessionId: syntheticSession.sessionId, text: "send to synthetic")
        let capturedThreadId = await sentThreadId.get()
        let capturedText = await sentText.get()

        XCTAssertTrue(success)
        XCTAssertEqual(capturedThreadId, "app-thread-1")
        XCTAssertEqual(capturedText, "send to synthetic")
    }

    @MainActor
    func testVisibleLocalThreadBecomesPrimarySessionAndKeepsHookTerminalMetadata() async throws {
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(
            id: "local-app-server",
            name: "Local App Server",
            sshTarget: "local-app-server",
            defaultCwd: "",
            isEnabled: true
        )
        let localMonitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: TestDiagnosticsLogger(),
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(localMonitor)

        let sessionMonitor = CodexSessionMonitor(localAppServerMonitor: localMonitor)
        TestObjectRetainer.retain(sessionMonitor)

        let transcriptPath = "/Users/test/.codex/sessions/2026/04/03/rollout-2026-04-03T14-40-04-hook-session.jsonl"

        localMonitor.startMonitoring()
        await SessionStore.shared.process(.hookReceived(
            HookEvent(
                sessionId: "hook-session",
                provider: .codex,
                cwd: "/tmp/primary-project",
                transcriptPath: transcriptPath,
                event: "SessionStart",
                status: "waiting_for_input",
                pid: 123,
                tty: "/dev/ttys001",
                terminalName: "Apple_Terminal",
                terminalWindowId: "window-1",
                terminalTabId: "tab-1",
                terminalSurfaceId: nil,
                turnId: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: nil,
                message: nil
            )
        ))
        await Task.yield()

        localMonitor.apply(event: .threadUpsert(
            hostId: host.id,
            thread: makeThread(
                id: "app-thread-visible",
                preview: "Visible Thread",
                status: .idle,
                turns: [
                    makeTurn(
                        items: [.agentMessage(id: "assistant-1", text: "hello primary thread")],
                        status: .completed
                    )
                ],
                cwd: "/tmp/primary-project",
                path: transcriptPath
            )
        ))
        await Task.yield()

        XCTAssertEqual(sessionMonitor.instances.count, 1)
        guard let session = sessionMonitor.instances.first else {
            return XCTFail("Expected merged local session")
        }

        XCTAssertEqual(session.sessionId, "app-thread-visible")
        XCTAssertEqual(session.logicalSessionId, "remote|local-app-server|/tmp/primary-project")
        XCTAssertEqual(session.tty, "ttys001")
        XCTAssertEqual(session.terminalWindowId, "window-1")
        XCTAssertEqual(session.displayTitle, "Visible Thread")
        XCTAssertEqual(session.transcriptPath, transcriptPath)
    }

    @MainActor
    func testChatHistoryManagerTracksVisibleLocalThreadHistory() async throws {
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(
            id: "local-app-server",
            name: "Local App Server",
            sshTarget: "local-app-server",
            defaultCwd: "",
            isEnabled: true
        )
        let localMonitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: TestDiagnosticsLogger(),
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(localMonitor)

        let sessionMonitor = CodexSessionMonitor(localAppServerMonitor: localMonitor)
        TestObjectRetainer.retain(sessionMonitor)

        localMonitor.startMonitoring()
        localMonitor.apply(event: .threadUpsert(
            hostId: host.id,
            thread: makeThread(
                id: "app-thread-history",
                preview: "History Thread",
                status: .idle,
                turns: [
                    makeTurn(
                        items: [
                            .userMessage(id: "user-1", content: [.text("app-server history")]),
                            .agentMessage(id: "assistant-1", text: "cached reply")
                        ],
                        status: .completed
                    )
                ],
                cwd: "/tmp/history-project"
            )
        ))
        await Task.yield()

        guard let session = sessionMonitor.instances.first(where: { $0.sessionId == "app-thread-history" }) else {
            return XCTFail("Expected visible local thread session")
        }

        let cachedHistory = ChatHistoryManager.shared.history(for: session.logicalSessionId)
        XCTAssertEqual(cachedHistory.count, 2)
        XCTAssertTrue(
            ChatHistoryManager.shared.isLoaded(
                logicalSessionId: session.logicalSessionId,
                sessionId: session.sessionId
            )
        )
    }

    @MainActor
    func testArchiveSyntheticLocalSessionHidesItFromInstances() async throws {
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(
            id: "local-app-server",
            name: "Local App Server",
            sshTarget: "local-app-server",
            defaultCwd: "",
            isEnabled: true
        )
        let localMonitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: TestDiagnosticsLogger(),
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(localMonitor)

        let sessionMonitor = CodexSessionMonitor(localAppServerMonitor: localMonitor)
        TestObjectRetainer.retain(sessionMonitor)

        localMonitor.startMonitoring()
        localMonitor.apply(event: .threadUpsert(
            hostId: host.id,
            thread: makeThread(
                id: "app-thread-archive",
                preview: "Archive Me",
                status: .idle,
                cwd: "/tmp/archive-project"
            )
        ))
        await Task.yield()

        XCTAssertNotNil(sessionMonitor.instances.first(where: { $0.sessionId == "app-thread-archive" }))

        sessionMonitor.archiveSession(sessionId: "app-thread-archive")
        await Task.yield()

        XCTAssertNil(sessionMonitor.instances.first(where: { $0.sessionId == "app-thread-archive" }))
    }

    @MainActor
    func testStartFreshLocalThreadUsesRequestedCwdAndReturnsSession() async throws {
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(
            id: "local-app-server",
            name: "Local App Server",
            sshTarget: "local-app-server",
            defaultCwd: "",
            isEnabled: true
        )
        let localMonitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: TestDiagnosticsLogger(),
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(localMonitor)

        let capturedCwd = LockedBox<String?>(nil)
        connection.startThreadHandler = { defaultCwd in
            await capturedCwd.set(defaultCwd)
            return await makeThreadStartResponse(
                thread: makeThread(
                    id: "fresh-local-thread",
                    preview: "Fresh Local",
                    status: .idle,
                    cwd: defaultCwd
                ),
                cwd: defaultCwd
            )
        }

        let sessionMonitor = CodexSessionMonitor(localAppServerMonitor: localMonitor)
        TestObjectRetainer.retain(sessionMonitor)

        localMonitor.startMonitoring()

        let opened = try await sessionMonitor.startFreshLocalThread(cwd: "/tmp/fresh-project")
        let observedCwd = await capturedCwd.get()

        XCTAssertEqual(observedCwd, "/tmp/fresh-project")
        XCTAssertEqual(opened.sessionId, "fresh-local-thread")
        XCTAssertEqual(opened.cwd, "/tmp/fresh-project")
        XCTAssertTrue(sessionMonitor.instances.contains(where: { $0.sessionId == "fresh-local-thread" }))
    }

    @MainActor
    func testOpenLocalThreadReturnsSyntheticSession() async throws {
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(
            id: "local-app-server",
            name: "Local App Server",
            sshTarget: "local-app-server",
            defaultCwd: "",
            isEnabled: true
        )
        let localMonitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: TestDiagnosticsLogger(),
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(localMonitor)

        connection.resumeThreadHandler = { threadId, _ in
            XCTAssertEqual(threadId, "resume-local-thread")
            return await makeThreadResumeResponse(
                thread: makeThread(
                    id: threadId,
                    preview: "Resumed Local",
                    status: .idle,
                    turns: [
                        makeTurn(
                            items: [.agentMessage(id: "assistant-1", text: "restored")],
                            status: .completed
                        )
                    ],
                    cwd: "/tmp/resume-project"
                ),
                cwd: "/tmp/resume-project"
            )
        }

        let sessionMonitor = CodexSessionMonitor(localAppServerMonitor: localMonitor)
        TestObjectRetainer.retain(sessionMonitor)

        localMonitor.startMonitoring()

        let opened = try await sessionMonitor.openLocalThread(threadId: "resume-local-thread")

        XCTAssertEqual(opened.sessionId, "resume-local-thread")
        XCTAssertEqual(opened.displayTitle, "Resumed Local")
        XCTAssertEqual(opened.lastMessage, "restored")
        XCTAssertTrue(sessionMonitor.instances.contains(where: { $0.sessionId == "resume-local-thread" }))
    }

    // 用最小问题集构造 codexLocal 交互，避免每个 presentation mode 用例都重复手写 transport 细节。
    private func makeInteraction(questions: [PendingInteractionQuestion]) -> PendingUserInputInteraction {
        PendingUserInputInteraction(
            id: "call-1",
            title: "Codex needs your input",
            questions: questions,
            transport: .codexLocal(callId: "call-1", turnId: "turn-1")
        )
    }

    @MainActor
    private func makeLocalAppServerHarness() -> LocalAppServerHarness {
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(
            id: "local-app-server",
            name: "Local App Server",
            sshTarget: "local-app-server",
            defaultCwd: "",
            isEnabled: true
        )
        let localMonitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: TestDiagnosticsLogger(),
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(localMonitor)

        let sessionMonitor = CodexSessionMonitor(localAppServerMonitor: localMonitor)
        TestObjectRetainer.retain(sessionMonitor)

        return LocalAppServerHarness(
            connection: connection,
            host: host,
            localMonitor: localMonitor,
            sessionMonitor: sessionMonitor
        )
    }

    // 统一最小 SessionStart hook payload，供 transcript / local app-server 绑定类测试复用。
    private func makeHookEvent(
        sessionId: String,
        transcriptPath: String? = nil,
        cwd: String = "/tmp/project"
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            provider: .codex,
            cwd: cwd,
            transcriptPath: transcriptPath,
            event: "SessionStart",
            status: "waiting_for_input",
            pid: 123,
            tty: nil,
            terminalName: "Apple_Terminal",
            terminalWindowId: nil,
            terminalTabId: nil,
            terminalSurfaceId: nil,
            turnId: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil
        )
    }

    // SessionStore 是跨测试共享 actor；每个用例前后都清理，避免 logical session 串台。
    private func resetSessionStore() async {
        let sessions = await SessionStore.shared.allSessions()
        for session in sessions {
            await SessionStore.shared.process(.sessionEnded(sessionId: session.sessionId))
        }
    }
}

// 简单 actor 盒子，用来在 async handler 里记录观察值而不引入数据竞争。
actor LockedBox<Value: Sendable> {
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        value
    }
}

@MainActor
private struct LocalAppServerHarness {
    let connection: FakeRemoteConnection
    let host: RemoteHostConfig
    let localMonitor: RemoteSessionMonitor
    let sessionMonitor: CodexSessionMonitor
}
