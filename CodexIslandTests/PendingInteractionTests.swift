import XCTest
@testable import Codex_Island

final class PendingInteractionTests: XCTestCase {
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

        localMonitor.apply(event: .threadUpsert(
            hostId: host.id,
            thread: makeThread(id: "session-1", status: .idle)
        ))
        localMonitor.apply(event: .userInputRequest(
            hostId: host.id,
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

        let session = try XCTUnwrap(sessionMonitor.instances.first(where: { $0.sessionId == "session-1" }))
        XCTAssertEqual(sessionMonitor.pendingInteraction(for: session)?.id, "remote-request")
        XCTAssertEqual(session.pendingInteractions.first?.id, "remote-request")
        XCTAssertTrue(session.needsAttention)
    }

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

        XCTAssertNil(sessionMonitor.localAppServerThreads[hiddenThreadId])

        let success = await sessionMonitor.sendMessage(sessionId: hiddenThreadId, text: "use raw thread")
        let capturedThreadId = await sentThreadId.get()

        XCTAssertTrue(success)
        XCTAssertEqual(capturedThreadId, hiddenThreadId)
    }

    @MainActor
    func testLocalListModelsUsesAppServerConnection() async throws {
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

        let includeHiddenFlag = LockedBox<Bool?>(nil)
        connection.listModelsHandler = { includeHidden in
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

        let models = try await sessionMonitor.listLocalModels(sessionId: "session-1", includeHidden: true)
        let capturedIncludeHidden = await includeHiddenFlag.get()

        XCTAssertEqual(capturedIncludeHidden, true)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.model, "gpt-5.4")
    }

    @MainActor
    func testLocalSetTurnContextUsesAppServerThread() async throws {
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

        let capturedContext = LockedBox<RemoteThreadTurnContext?>(nil)
        connection.resumeThreadHandler = { threadId, turnContext in
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

        let updatedThread = try await sessionMonitor.setLocalTurnContext(
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

        connection.listCollaborationModesHandler = {
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

        let modes = try await sessionMonitor.listLocalCollaborationModes(sessionId: "session-1")

        XCTAssertEqual(modes.count, 2)
        XCTAssertEqual(modes.last?.mode, .plan)
        XCTAssertEqual(modes.last?.reasoningEffort, .high)
    }

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

    private func makeInteraction(questions: [PendingInteractionQuestion]) -> PendingUserInputInteraction {
        PendingUserInputInteraction(
            id: "call-1",
            title: "Codex needs your input",
            questions: questions,
            transport: .codexLocal(callId: "call-1", turnId: "turn-1")
        )
    }

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

    private func resetSessionStore() async {
        let sessions = await SessionStore.shared.allSessions()
        for session in sessions {
            await SessionStore.shared.process(.sessionEnded(sessionId: session.sessionId))
        }
    }
}

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
