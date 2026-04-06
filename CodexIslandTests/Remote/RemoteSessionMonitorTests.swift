import XCTest
@testable import Codex_Island

private typealias RemoteMonitorEventEmitter = @Sendable (RemoteConnectionEvent) async -> Void

@MainActor
final class RemoteSessionMonitorTests: XCTestCase {
    // 这里锁住远端监控器的核心状态机：host 更新、optimistic send、thread 选择、事件应用和 transcript fallback。
    func testUpdateHostClearsOldThreadsWhenSSHTargetChanges() async throws {
        let logger = TestDiagnosticsLogger()
        let originalHost = RemoteHostConfig(
            id: "host-1",
            name: "Old",
            sshTarget: "cd",
            defaultCwd: "/repo",
            isEnabled: true
        )
        let updatedHost = RemoteHostConfig(
            id: "host-1",
            name: "New",
            sshTarget: "100.114.242.113",
            defaultCwd: "/repo",
            isEnabled: true
        )
        let oldConnection = FakeRemoteConnection()
        let newConnection = FakeRemoteConnection()
        let oldThread = makeThread(id: "thread-old", preview: "Old Session", cwd: "/repo")
        var factoryCalls = 0

        let monitor = RemoteSessionMonitor(
            initialHosts: [originalHost],
            loadHosts: { [originalHost] in [originalHost] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { host, emit in
                factoryCalls += 1
                if factoryCalls == 1 {
                    oldConnection.emit = emit
                    return oldConnection
                }
                XCTAssertEqual(host.sshTarget, updatedHost.sshTarget)
                newConnection.emit = emit
                return newConnection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        monitor.apply(event: .connectionState(hostId: originalHost.id, state: .connected))
        monitor.apply(event: .threadUpsert(hostId: originalHost.id, thread: oldThread))

        XCTAssertEqual(monitor.threads.count, 1)
        XCTAssertEqual(monitor.threads.first?.threadId, "thread-old")

        monitor.updateHost(updatedHost)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(oldConnection.stopCalled)
        XCTAssertTrue(newConnection.startCalled)
        XCTAssertTrue(monitor.threads.isEmpty)
        XCTAssertEqual(monitor.hostStates[originalHost.id], .disconnected)
        XCTAssertNil(monitor.hostActionErrors[originalHost.id])
    }

    func testUpdateHostKeepsThreadsWhenOnlyNameChanges() async {
        let logger = TestDiagnosticsLogger()
        let originalHost = RemoteHostConfig(
            id: "host-1",
            name: "Old",
            sshTarget: "cd",
            defaultCwd: "/repo",
            isEnabled: true
        )
        let renamedHost = RemoteHostConfig(
            id: "host-1",
            name: "Renamed",
            sshTarget: "cd",
            defaultCwd: "/repo",
            isEnabled: true
        )
        let connection = FakeRemoteConnection()
        let oldThread = makeThread(id: "thread-old", preview: "Old Session", cwd: "/repo")

        let monitor = RemoteSessionMonitor(
            initialHosts: [originalHost],
            loadHosts: { [originalHost] in [originalHost] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        monitor.apply(event: .connectionState(hostId: originalHost.id, state: .connected))
        monitor.apply(event: .threadUpsert(hostId: originalHost.id, thread: oldThread))

        monitor.updateHost(renamedHost)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(connection.stopCalled)
        XCTAssertEqual(monitor.threads.count, 1)
        XCTAssertEqual(monitor.threads.first?.threadId, "thread-old")
    }

    func testStartThreadRecoversNewThreadAfterTimeout() async throws {
        let harness = makeRemoteMonitorHarness()
        let recoveredThread = makeThread(id: "thread-new", preview: "Recovered")

        harness.connection.startThreadHandler = { _ in
            throw RemoteSessionError.timeout("Timed out waiting for app-server response to thread/start")
        }
        harness.connection.refreshThreadsHandler = {
            await harness.connection.emit?(.threadUpsert(hostId: harness.host.id, thread: recoveredThread))
        }

        harness.start()
        let recovered = try await harness.monitor.startThread(hostId: harness.host.id)

        XCTAssertEqual(recovered.threadId, "thread-new")
        XCTAssertNil(harness.monitor.hostActionErrors[harness.host.id])
    }

    // start/send timeout 会走 optimistic 路径；这些回归确保临时 user item 能补上、合并或回滚。
    func testSendMessageAddsOptimisticUserItemOnTimeout() async throws {
        let harness = makeRemoteMonitorHarness()
        let baseThread = makeThread(id: "thread-1", preview: "Preview", status: .idle)

        harness.connection.startThreadHandler = { _ in makeThreadStartResponse(thread: baseThread) }
        harness.connection.sendMessageHandler = { _, _, _, _ in
            throw RemoteSessionError.timeout("Timed out waiting for app-server response to turn/start")
        }

        harness.start()
        harness.upsert(baseThread)
        let thread = try XCTUnwrap(harness.monitor.threads.first)

        try await harness.monitor.sendMessage(thread: thread, text: "hi")

        let updated = try XCTUnwrap(harness.monitor.threads.first)
        XCTAssertEqual(updated.history.last?.type, .user("hi"))
        XCTAssertEqual(updated.phase, .processing)
    }

    func testSendMessageMergesOptimisticUserItemWhenServerUserMessageArrives() async throws {
        let harness = makeRemoteMonitorHarness()
        let baseThread = makeThread(id: "thread-1", preview: "Preview", status: .idle)

        harness.connection.startThreadHandler = { _ in makeThreadStartResponse(thread: baseThread) }
        harness.connection.sendMessageHandler = { _, _, _, _ in }

        harness.start()
        harness.upsert(baseThread)
        let thread = try XCTUnwrap(harness.monitor.threads.first)

        try await harness.monitor.sendMessage(thread: thread, text: "hi")
        harness.monitor.apply(event: .itemStarted(
            hostId: harness.host.id,
            threadId: "thread-1",
            turnId: "turn-1",
            item: .userMessage(id: "server-user-1", content: [.text("hi")])
        ))

        let updated = try XCTUnwrap(harness.monitor.threads.first)
        XCTAssertEqual(updated.history.count, 1)
        XCTAssertEqual(updated.history.first?.id, "server-user-1")
        XCTAssertEqual(updated.history.first?.type, .user("hi"))
    }

    func testSendMessageRemovesOptimisticUserItemOnFailure() async throws {
        let harness = makeRemoteMonitorHarness()
        let baseThread = makeThread(id: "thread-1", preview: "Preview", status: .idle)

        harness.connection.sendMessageHandler = { _, _, _, _ in
            throw RemoteSessionError.transport("boom")
        }

        harness.start()
        harness.upsert(baseThread)
        let thread = try XCTUnwrap(harness.monitor.threads.first)

        do {
            try await harness.monitor.sendMessage(thread: thread, text: "hi")
            XCTFail("Expected sendMessage to fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, "boom")
        }

        let updated = try XCTUnwrap(harness.monitor.threads.first)
        XCTAssertTrue(updated.history.isEmpty)
    }

    func testConnectionFailureDisablesSendAndSurfacesFailureMessage() async throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)
        let baseThread = makeThread(id: "thread-1", preview: "Preview", status: .idle)

        connection.sendMessageHandler = { _, _, _, _ in
            throw RemoteSessionError.notConnected
        }

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        monitor.apply(event: .threadUpsert(hostId: host.id, thread: baseThread))
        monitor.apply(event: .connectionState(hostId: host.id, state: .failed("SSH exited with code 255")))

        let thread = try XCTUnwrap(monitor.threads.first)
        XCTAssertFalse(thread.canSendMessage)
        XCTAssertEqual(thread.connectionFeedbackMessage, "SSH exited with code 255")
        XCTAssertEqual(monitor.hostActionErrors[host.id], "SSH exited with code 255")

        do {
            try await monitor.sendMessage(thread: thread, text: "hi")
            XCTFail("Expected sendMessage to fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, "SSH exited with code 255")
        }
    }

    // 事件应用层不仅维护 phase，也负责把 plan、token usage、approval 和 user input 翻译成可见状态。
    func testTurnPlanUpdatedAddsTodoWriteHistoryItem() throws {
        let harness = makeRemoteMonitorHarness()
        let thread = makeThread(id: "thread-1", preview: "Preview", status: .idle)

        harness.upsert(thread)
        harness.monitor.apply(event: .turnPlanUpdated(
            hostId: harness.host.id,
            threadId: "thread-1",
            turnId: "turn-1",
            explanation: "Syncing plan",
            plan: [
                RemoteAppServerPlanStep(step: "Inspect remote state", status: "completed"),
                RemoteAppServerPlanStep(step: "Patch UI", status: "in_progress")
            ]
        ))

        let updated = try XCTUnwrap(harness.monitor.threads.first)
        guard case .toolCall(let tool)? = updated.history.last?.type else {
            return XCTFail("Expected plan update tool call")
        }

        XCTAssertEqual(tool.name, "TodoWrite")
        XCTAssertEqual(tool.result, "Syncing plan\n- [completed] Inspect remote state\n- [in_progress] Patch UI")
        XCTAssertEqual(
            tool.structuredResult,
            .todoWrite(TodoWriteResult(
                oldTodos: [],
                newTodos: [
                    TodoItem(content: "Inspect remote state", status: "completed", activeForm: nil),
                    TodoItem(content: "Patch UI", status: "in_progress", activeForm: nil)
                ]
            ))
        )
    }

    func testTokenUsageUpdateSetsContextRemainingPercent() throws {
        let harness = makeRemoteMonitorHarness()
        let thread = makeThread(id: "thread-1", preview: "Preview", status: .idle)

        harness.upsert(thread)
        harness.monitor.apply(event: .tokenUsageUpdated(
            hostId: harness.host.id,
            threadId: "thread-1",
            turnId: "turn-1",
            tokenUsage: SessionTokenUsageInfo(
                totalTokenUsage: SessionTokenUsage(
                    inputTokens: 120_000,
                    cachedInputTokens: 0,
                    outputTokens: 3_000,
                    reasoningOutputTokens: 500,
                    totalTokens: 123_000
                ),
                lastTokenUsage: SessionTokenUsage(
                    inputTokens: 100_000,
                    cachedInputTokens: 0,
                    outputTokens: 0,
                    reasoningOutputTokens: 0,
                    totalTokens: 100_000
                ),
                modelContextWindow: 950_000
            )
        ))

        let updated = try XCTUnwrap(harness.monitor.threads.first)
        XCTAssertEqual(updated.contextRemainingPercent, 91)
        XCTAssertEqual(updated.tokenUsage?.totalTokenUsage.totalTokens, 123_000)
    }

    func testApprovalEventSetsPendingApprovalState() throws {
        let harness = makeRemoteMonitorHarness()
        let thread = makeThread(id: "thread-1", preview: "Preview", status: .idle)
        let approval = RemotePendingApproval(
            id: "approval-1",
            requestId: .int(1),
            kind: .commandExecution,
            itemId: "item-1",
            threadId: "thread-1",
            turnId: "turn-1",
            title: "Command Execution",
            detail: "pwd",
            requestedPermissions: .none,
            availableActions: [.allow, .cancel]
        )

        harness.upsert(thread)
        harness.monitor.apply(event: .approval(hostId: harness.host.id, threadId: "thread-1", approval: approval))

        let updated = try XCTUnwrap(harness.monitor.threads.first)
        XCTAssertEqual(updated.pendingApproval?.id, "approval-1")
        XCTAssertEqual(updated.phase.approvalToolName, "Command Execution")
        XCTAssertEqual(updated.pendingToolInput, "pwd")
    }

    func testUserInputRequestSetsPendingInteractionState() throws {
        let harness = makeRemoteMonitorHarness()
        let thread = makeThread(id: "thread-1", preview: "Preview", status: .idle)
        let interaction = PendingUserInputInteraction(
            id: "item-1",
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

        harness.upsert(thread)
        harness.monitor.apply(event: .userInputRequest(hostId: harness.host.id, threadId: "thread-1", interaction: interaction))

        let updated = try XCTUnwrap(harness.monitor.threads.first)
        XCTAssertEqual(updated.pendingInteractions.count, 1)
        XCTAssertEqual(updated.primaryPendingInteraction?.id, "item-1")
        XCTAssertTrue(updated.needsAttention)
    }

    func testServerRequestResolvedClearsPendingInteractionState() throws {
        let harness = makeRemoteMonitorHarness()
        let thread = makeThread(id: "thread-1", preview: "Preview", status: .idle)
        let interaction = PendingUserInputInteraction(
            id: "item-1",
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

        harness.upsert(thread)
        harness.monitor.apply(event: .userInputRequest(hostId: harness.host.id, threadId: "thread-1", interaction: interaction))
        harness.monitor.apply(event: .serverRequestResolved(hostId: harness.host.id, threadId: "thread-1", requestId: .int(7)))

        let updated = try XCTUnwrap(harness.monitor.threads.first)
        XCTAssertTrue(updated.pendingInteractions.isEmpty)
    }

    // thread/list 会对同 host + cwd 的线程做折叠，但选择规则必须优先保留更“活跃”的那条。
    func testThreadListCollapsesSameSSHAndCwdToLatestThread() {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "/repo", isEnabled: true)
        let olderThread = makeThread(id: "thread-1", preview: "Older", cwd: "/repo")
        let newerThread = RemoteAppServerThread(
            id: "thread-2",
            preview: "Newer",
            ephemeral: false,
            modelProvider: "openai",
            createdAt: 1_700_000_200,
            updatedAt: 1_700_000_300,
            status: .idle,
            path: nil,
            cwd: "/repo",
            cliVersion: "1.0.0",
            name: nil,
            turns: []
        )

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.apply(event: .threadList(hostId: host.id, threads: [olderThread, newerThread]))

        XCTAssertEqual(monitor.threads.count, 1)
        XCTAssertEqual(monitor.threads.first?.threadId, "thread-2")
        XCTAssertEqual(monitor.threads.first?.logicalSessionId, "remote|ssh-target|/repo")
    }

    func testThreadListPrefersProcessingThreadOverNewerIdleThreadForSameCwd() {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "/repo", isEnabled: true)
        let activeThread = RemoteAppServerThread(
            id: "thread-active",
            preview: "Active",
            ephemeral: false,
            modelProvider: "openai",
            createdAt: 1_700_000_000,
            updatedAt: 1_700_000_100,
            status: .active(activeFlags: []),
            path: nil,
            cwd: "/repo",
            cliVersion: "1.0.0",
            name: nil,
            turns: [
                makeTurn(
                    id: "turn-1",
                    items: [
                        .commandExecution(
                            id: "cmd-1",
                            command: "npm run dev",
                            cwd: "/repo",
                            status: .inProgress,
                            aggregatedOutput: nil
                        )
                    ],
                    status: .inProgress
                )
            ]
        )
        let newerIdleThread = RemoteAppServerThread(
            id: "thread-idle",
            preview: "Idle",
            ephemeral: false,
            modelProvider: "openai",
            createdAt: 1_700_000_200,
            updatedAt: 1_700_000_300,
            status: .idle,
            path: nil,
            cwd: "/repo",
            cliVersion: "1.0.0",
            name: nil,
            turns: []
        )

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.apply(event: .threadList(hostId: host.id, threads: [activeThread, newerIdleThread]))

        XCTAssertEqual(monitor.threads.count, 1)
        XCTAssertEqual(monitor.threads.first?.threadId, "thread-active")
        XCTAssertEqual(monitor.threads.first?.phase, .processing)
    }

    func testThreadListFiltersThreadsToConfiguredDefaultCwd() {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "/repo", isEnabled: true)
        let matchingThread = makeThread(id: "thread-1", preview: "Repo", cwd: "/repo")
        let otherThread = makeThread(id: "thread-2", preview: "Other", cwd: "/other")

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        monitor.apply(event: .threadList(hostId: host.id, threads: [matchingThread, otherThread]))

        XCTAssertEqual(monitor.threads.count, 1)
        XCTAssertEqual(monitor.threads.first?.threadId, "thread-1")
        XCTAssertEqual(monitor.threads.first?.cwd, "/repo")
    }

    func testThreadListKeepsAllThreadsWhenDefaultCwdIsEmpty() {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)
        let firstThread = makeThread(id: "thread-1", preview: "Repo", cwd: "/repo")
        let secondThread = makeThread(id: "thread-2", preview: "Other", cwd: "/other")

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        monitor.apply(event: .threadList(hostId: host.id, threads: [firstThread, secondThread]))

        XCTAssertEqual(monitor.threads.count, 2)
        XCTAssertEqual(Set(monitor.threads.map(\.threadId)), Set(["thread-1", "thread-2"]))
    }

    func testThreadListTreatsInProgressCommandItemAsProcessingEvenWhenThreadStatusIsIdle() {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "/repo", isEnabled: true)
        let thread = makeThread(
            id: "thread-1",
            preview: "Repo",
            status: .idle,
            turns: [
                makeTurn(
                    id: "turn-1",
                    items: [
                        .commandExecution(
                            id: "cmd-1",
                            command: "npm run dev",
                            cwd: "/repo",
                            status: .inProgress,
                            aggregatedOutput: nil
                        )
                    ],
                    status: .completed
                )
            ],
            cwd: "/repo"
        )

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        monitor.apply(event: .threadList(hostId: host.id, threads: [thread]))

        XCTAssertEqual(monitor.threads.count, 1)
        XCTAssertEqual(monitor.threads.first?.phase, .processing)
        XCTAssertEqual(monitor.threads.first?.activeTurnId, "turn-1")
        XCTAssertEqual(monitor.threads.first?.history.last?.type, .toolCall(ToolCallItem(
            name: "Command",
            input: ["command": "npm run dev"],
            status: .running,
            result: nil,
            structuredResult: nil,
            subagentTools: []
        )))
    }

    func testTurnCompletedBackfillsFinalAssistantMessageWhenConnectedMidTurn() throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "/repo", isEnabled: true)
        let thread = makeThread(
            id: "thread-1",
            preview: "Repo",
            status: .active(activeFlags: []),
            turns: [
                makeTurn(
                    id: "turn-1",
                    items: [
                        .commandExecution(
                            id: "cmd-1",
                            command: "npm run dev",
                            cwd: "/repo",
                            status: .inProgress,
                            aggregatedOutput: nil
                        )
                    ],
                    status: .inProgress
                )
            ],
            cwd: "/repo"
        )

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        monitor.apply(event: .threadList(hostId: host.id, threads: [thread]))
        monitor.apply(event: .agentMessageDelta(
            hostId: host.id,
            threadId: "thread-1",
            turnId: "turn-1",
            itemId: "assistant-1",
            delta: "- "
        ))
        monitor.apply(event: .turnCompleted(
            hostId: host.id,
            threadId: "thread-1",
            turn: makeTurn(
                id: "turn-1",
                items: [
                    .commandExecution(
                        id: "cmd-1",
                        command: "npm run dev",
                        cwd: "/repo",
                        status: .completed,
                        aggregatedOutput: "done"
                    ),
                    .agentMessage(id: "assistant-1", text: "最终结论已经同步")
                ],
                status: .completed
            )
        ))

        let updated = try XCTUnwrap(monitor.threads.first)
        XCTAssertEqual(updated.phase, .waitingForInput)
        XCTAssertNil(updated.activeTurnId)
        XCTAssertEqual(updated.history.last?.type, .assistant("最终结论已经同步"))
    }

    func testStartThreadReturnsExistingLogicalSessionForSameCwd() async throws {
        final class CallTracker: @unchecked Sendable {
            var didCallStart = false
        }

        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "/repo", isEnabled: true)
        let existingThread = makeThread(id: "thread-existing", preview: "Existing", cwd: "/repo")
        let tracker = CallTracker()

        connection.startThreadHandler = { _ in
            tracker.didCallStart = true
            return makeThreadStartResponse(thread: makeThread(id: "thread-new", preview: "New", cwd: "/repo"))
        }

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        monitor.apply(event: .threadUpsert(hostId: host.id, thread: existingThread))

        let opened = try await monitor.startThread(hostId: host.id)

        XCTAssertFalse(tracker.didCallStart)
        XCTAssertEqual(opened.threadId, "thread-existing")
        XCTAssertEqual(monitor.threads.count, 1)
    }

    func testCreateThreadOpensExistingLogicalSessionBeforeCallback() async throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "/repo", isEnabled: true)
        let existingThread = makeThread(id: "thread-existing", preview: "Existing", cwd: "/repo")
        let resumedThread = RemoteAppServerThread(
            id: "thread-existing",
            preview: "Existing",
            ephemeral: false,
            modelProvider: "openai",
            createdAt: 1_700_000_000,
            updatedAt: 1_700_000_100,
            status: .idle,
            path: nil,
            cwd: "/repo",
            cliVersion: "1.0.0",
            name: nil,
            turns: [
                RemoteAppServerTurn(
                    id: "turn-1",
                    items: [.userMessage(id: "user-1", content: [.text("hello")])],
                    status: .completed,
                    error: nil
                )
            ]
        )

        connection.resumeThreadHandler = { _, _ in
            makeThreadResumeResponse(thread: resumedThread)
        }

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        monitor.apply(event: .threadUpsert(hostId: host.id, thread: existingThread))

        let callbackThread = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RemoteThreadState, Error>) in
            monitor.createThread(hostId: host.id) { thread in
                continuation.resume(returning: thread)
            }
        }

        XCTAssertEqual(callbackThread.threadId, "thread-existing")
        XCTAssertEqual(callbackThread.history.count, 1)
        XCTAssertEqual(callbackThread.history.first?.type, .user("hello"))
    }

    func testOpenThreadPreservesCollaborationModeFromResumeResponse() async throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "/repo", isEnabled: true)
        let existingThread = makeThread(id: "thread-existing", preview: "Existing", cwd: "/repo")
        let resumedThread = makeThread(
            id: "thread-existing",
            preview: "Existing",
            status: .active(activeFlags: [.waitingOnUserInput]),
            turns: [
                makeTurn(
                    id: "turn-1",
                    items: [.plan(id: "plan-1", text: "plan body")],
                    status: .completed
                )
            ],
            cwd: "/repo"
        )

        connection.resumeThreadHandler = { _, _ in
            makeThreadResumeResponse(
                thread: resumedThread,
                collaborationMode: RemoteAppServerCollaborationMode(
                    mode: .plan,
                    settings: RemoteAppServerCollaborationSettings(
                        developerInstructions: nil,
                        model: "gpt-5.4",
                        reasoningEffort: .medium
                    )
                )
            )
        }

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        monitor.apply(event: .threadUpsert(hostId: host.id, thread: existingThread))

        let opened = try await monitor.openThread(hostId: host.id, threadId: "thread-existing")
        XCTAssertEqual(opened.turnContext.collaborationMode?.mode, .plan)
        XCTAssertEqual(opened.phase, .waitingForInput)
    }

    func testThreadListAppliesTranscriptFallbackWhenAppServerSnapshotIsIdle() async throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "/repo", isEnabled: true)
        let thread = makeThread(
            id: "thread-1",
            preview: "Existing",
            status: .idle,
            turns: [],
            cwd: "/repo",
            path: "/remote/thread-1.jsonl"
        )

        connection.transcriptSnapshotHandler = { _, _, _ in
            RemoteTranscriptFallbackSnapshot(
                history: [
                    ChatHistoryItem(id: "assistant-1", type: .assistant("plan body"), timestamp: Date())
                ],
                pendingInteractions: [
                    .userInput(PendingUserInputInteraction(
                        id: "plan-choice",
                        title: "Codex needs your input",
                        questions: [
                            PendingInteractionQuestion(
                                id: "plan_mode_followup",
                                header: "Next step",
                                question: "Implement this plan?",
                                options: [
                                    PendingInteractionOption(label: "Yes", description: nil),
                                    PendingInteractionOption(label: "No", description: nil)
                                ],
                                isOther: false,
                                isSecret: false
                            )
                        ],
                        transport: .codexLocal(callId: nil, turnId: "turn-1")
                    ))
                ],
                transcriptPhase: .waitingForInput,
                runtimeInfo: .empty
            )
        }

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        monitor.apply(event: .connectionState(hostId: host.id, state: .connected))
        monitor.apply(event: .threadList(hostId: host.id, threads: [thread]))

        try await waitUntil {
            let updated = await MainActor.run { monitor.threads.first }
            guard let updated else { return false }
            return updated.phase == .waitingForInput && updated.primaryPendingInteraction != nil && !updated.canSendMessage
        }

        let updated = try XCTUnwrap(monitor.threads.first)
        XCTAssertEqual(updated.phase, .waitingForInput)
        XCTAssertEqual(updated.history.last?.type, .assistant("plan body"))
        XCTAssertFalse(updated.canSendMessage)
    }

    func testIdleThreadListDoesNotOverrideFreshTranscriptProcessingState() async throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "/repo", isEnabled: true)
        let thread = makeThread(
            id: "thread-1",
            preview: "Existing",
            status: .idle,
            turns: [],
            cwd: "/repo",
            path: "/remote/thread-1.jsonl"
        )

        connection.transcriptSnapshotHandler = { _, _, _ in
            RemoteTranscriptFallbackSnapshot(
                history: [
                    ChatHistoryItem(id: "assistant-1", type: .assistant("still running"), timestamp: Date())
                ],
                pendingInteractions: [],
                transcriptPhase: .processing,
                runtimeInfo: .empty
            )
        }

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        monitor.apply(event: .connectionState(hostId: host.id, state: .connected))
        monitor.apply(event: .threadList(hostId: host.id, threads: [thread]))

        try await waitUntil {
            let updated = await MainActor.run { monitor.threads.first }
            return updated?.phase == .processing
        }

        let first = try XCTUnwrap(monitor.threads.first)
        XCTAssertEqual(first.phase, .processing)
        XCTAssertFalse(first.canSendMessage)

        monitor.apply(event: .threadList(hostId: host.id, threads: [thread]))

        let second = try XCTUnwrap(monitor.threads.first)
        XCTAssertEqual(second.phase, .processing)
        XCTAssertFalse(second.canSendMessage)
    }

    // transcript fallback 只在 app-server 快照不足时兜底，而且不能把更新鲜的 processing 状态覆盖回 idle。
    func testFreshIdleThreadStartsAsProcessingWhileTranscriptFallbackIsPending() {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "/repo", isEnabled: true)
        let thread = RemoteAppServerThread(
            id: "thread-1",
            preview: "Existing",
            ephemeral: false,
            modelProvider: "openai",
            createdAt: 1_700_000_000,
            updatedAt: Int64(Date().timeIntervalSince1970),
            status: .idle,
            path: "/remote/thread-1.jsonl",
            cwd: "/repo",
            cliVersion: "1.0.0",
            name: nil,
            turns: []
        )

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        monitor.apply(event: .connectionState(hostId: host.id, state: .connected))
        monitor.apply(event: .threadList(hostId: host.id, threads: [thread]))

        let inserted = try? XCTUnwrap(monitor.threads.first)
        XCTAssertEqual(inserted?.phase, .processing)
        XCTAssertFalse(inserted?.canSendMessage ?? true)
    }

    func testStartFreshThreadBypassesLogicalSessionReuse() async throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "/repo", isEnabled: true)
        let existingThread = makeThread(id: "thread-existing", preview: "Existing", cwd: "/repo")
        let freshThread = makeThread(id: "thread-new", preview: "Fresh", cwd: "/repo")
        final class StartTracker: @unchecked Sendable {
            var didCallStart = false
        }
        let tracker = StartTracker()

        connection.startThreadHandler = { _ in
            tracker.didCallStart = true
            return makeThreadStartResponse(thread: freshThread)
        }

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        monitor.apply(event: .threadUpsert(hostId: host.id, thread: existingThread))

        let opened = try await monitor.startFreshThread(hostId: host.id)

        XCTAssertTrue(tracker.didCallStart)
        XCTAssertEqual(opened.threadId, "thread-new")
        XCTAssertEqual(monitor.threads.count, 1)
        XCTAssertEqual(monitor.threads.first?.threadId, "thread-new")
        XCTAssertEqual(
            Set(monitor.availableThreads(hostId: host.id).map(\.threadId)),
            Set(["thread-existing", "thread-new"])
        )
    }

    func testAvailableThreadsIncludesHiddenSameCwdThreads() async {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "/repo", isEnabled: true)
        let olderThread = makeThread(id: "thread-older", preview: "Older", cwd: "/repo")
        let newerThread = RemoteAppServerThread(
            id: "thread-newer",
            preview: "Newer",
            ephemeral: false,
            modelProvider: "openai",
            createdAt: 1_700_000_100,
            updatedAt: 1_700_000_200,
            status: .idle,
            path: nil,
            cwd: "/repo",
            cliVersion: "1.0.0",
            name: nil,
            turns: []
        )

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        monitor.apply(event: .threadList(hostId: host.id, threads: [olderThread, newerThread]))

        XCTAssertEqual(monitor.threads.count, 1)
        XCTAssertEqual(monitor.threads.first?.threadId, "thread-newer")
        XCTAssertEqual(
            monitor.availableThreads(hostId: host.id, excluding: "thread-newer").map(\.threadId),
            ["thread-older"]
        )
    }

    // 显式 open/start fresh 建立的 preferred thread 选择，后续 refresh 不能再被同 cwd 的别的线程顶掉。
    func testOpenThreadKeepsExplicitSameCwdSelectionAfterRefresh() async throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "/repo", isEnabled: true)
        let olderThread = RemoteAppServerThread(
            id: "thread-older",
            preview: "Older",
            ephemeral: false,
            modelProvider: "openai",
            createdAt: 1_700_000_000,
            updatedAt: 1_700_000_050,
            status: .idle,
            path: nil,
            cwd: "/repo",
            cliVersion: "1.0.0",
            name: nil,
            turns: []
        )
        let newerThread = RemoteAppServerThread(
            id: "thread-newer",
            preview: "Newer",
            ephemeral: false,
            modelProvider: "openai",
            createdAt: 1_700_000_100,
            updatedAt: 1_700_000_200,
            status: .idle,
            path: nil,
            cwd: "/repo",
            cliVersion: "1.0.0",
            name: nil,
            turns: []
        )
        let resumedOlderThread = RemoteAppServerThread(
            id: "thread-older",
            preview: "Older",
            ephemeral: false,
            modelProvider: "openai",
            createdAt: 1_700_000_000,
            updatedAt: 1_700_000_050,
            status: .idle,
            path: nil,
            cwd: "/repo",
            cliVersion: "1.0.0",
            name: nil,
            turns: [
                RemoteAppServerTurn(
                    id: "turn-1",
                    items: [.userMessage(id: "user-1", content: [.text("resume me")])],
                    status: .completed,
                    error: nil
                )
            ]
        )

        connection.resumeThreadHandler = { threadId, _ in
            XCTAssertEqual(threadId, "thread-older")
            return makeThreadResumeResponse(thread: resumedOlderThread)
        }

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        monitor.apply(event: .threadList(hostId: host.id, threads: [olderThread, newerThread]))
        XCTAssertEqual(monitor.threads.first?.threadId, "thread-newer")

        let opened = try await monitor.openThread(hostId: host.id, threadId: "thread-older")
        XCTAssertEqual(opened.threadId, "thread-older")
        XCTAssertEqual(opened.history.first?.type, .user("resume me"))

        monitor.apply(event: .threadList(hostId: host.id, threads: [olderThread, newerThread]))

        XCTAssertEqual(monitor.threads.count, 1)
        XCTAssertEqual(monitor.threads.first?.threadId, "thread-older")
    }

    func testThreadListRetainsFreshPreferredThreadWhenListTemporarilyOmitsIt() async throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "/repo", isEnabled: true)
        let oldThread = RemoteAppServerThread(
            id: "thread-old",
            preview: "Old",
            ephemeral: false,
            modelProvider: "openai",
            createdAt: 1_700_000_000,
            updatedAt: 1_700_000_100,
            status: .idle,
            path: nil,
            cwd: "/repo",
            cliVersion: "1.0.0",
            name: nil,
            turns: []
        )
        let newThread = RemoteAppServerThread(
            id: "thread-new",
            preview: "",
            ephemeral: false,
            modelProvider: "openai",
            createdAt: 1_700_000_200,
            updatedAt: 1_700_000_200,
            status: .idle,
            path: nil,
            cwd: "/repo",
            cliVersion: "1.0.0",
            name: nil,
            turns: []
        )

        connection.startThreadHandler = { _ in
            makeThreadStartResponse(thread: newThread)
        }

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        monitor.apply(event: .threadList(hostId: host.id, threads: [oldThread]))
        XCTAssertEqual(monitor.threads.first?.threadId, "thread-old")

        let opened = try await monitor.startFreshThread(hostId: host.id)
        XCTAssertEqual(opened.threadId, "thread-new")
        XCTAssertEqual(monitor.threads.first?.threadId, "thread-new")

        monitor.apply(event: .threadList(hostId: host.id, threads: [oldThread]))

        XCTAssertEqual(monitor.threads.count, 1)
        XCTAssertEqual(monitor.threads.first?.threadId, "thread-new")
        XCTAssertEqual(
            Set(monitor.availableThreads(hostId: host.id).map(\.threadId)),
            Set(["thread-old", "thread-new"])
        )
    }

    func testCreateThreadDoesNotResumeFreshlyStartedEmptyThread() async throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "/repo", isEnabled: true)
        let freshThread = makeThread(id: "thread-new", preview: "New", cwd: "/repo")
        final class ResumeTracker: @unchecked Sendable {
            var didResume = false
        }
        let tracker = ResumeTracker()

        connection.startThreadHandler = { _ in
            makeThreadStartResponse(thread: freshThread)
        }
        connection.resumeThreadHandler = { _, _ in
            tracker.didResume = true
            return makeThreadResumeResponse(thread: freshThread)
        }

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()

        let callbackThread = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RemoteThreadState, Error>) in
            monitor.createThread(hostId: host.id) { thread in
                continuation.resume(returning: thread)
            }
        }

        XCTAssertEqual(callbackThread.threadId, "thread-new")
        XCTAssertFalse(tracker.didResume)
    }
}

@MainActor
private struct RemoteMonitorHarness {
    let logger: TestDiagnosticsLogger
    let host: RemoteHostConfig
    let connection: FakeRemoteConnection
    let monitor: RemoteSessionMonitor

    func start() {
        monitor.startMonitoring()
    }

    func applyConnected() {
        monitor.apply(event: .connectionState(hostId: host.id, state: .connected))
    }

    func applyFailed(_ message: String) {
        monitor.apply(event: .connectionState(hostId: host.id, state: .failed(message)))
    }

    func upsert(_ thread: RemoteAppServerThread) {
        monitor.apply(event: .threadUpsert(hostId: host.id, thread: thread))
    }

    func list(_ threads: [RemoteAppServerThread]) {
        monitor.apply(event: .threadList(hostId: host.id, threads: threads))
    }
}

@MainActor
private func makeRemoteMonitorHarness(
    host: RemoteHostConfig = RemoteHostConfig(
        id: "host-1",
        name: "Remote",
        sshTarget: "ssh-target",
        defaultCwd: "",
        isEnabled: true
    ),
    connection: FakeRemoteConnection = FakeRemoteConnection(),
    connectionFactoryOverride: ((RemoteHostConfig, @escaping RemoteMonitorEventEmitter) -> any RemoteAppServerConnectionProtocol)? = nil
) -> RemoteMonitorHarness {
    let logger = TestDiagnosticsLogger()
    let monitor = RemoteSessionMonitor(
        initialHosts: [host],
        loadHosts: { [host] in [host] },
        saveHosts: { _ in },
        diagnosticsLogger: logger,
        connectionFactory: connectionFactoryOverride ?? { _, emit in
            connection.emit = emit
            return connection
        }
    )
    TestObjectRetainer.retain(monitor)
    return RemoteMonitorHarness(
        logger: logger,
        host: host,
        connection: connection,
        monitor: monitor
    )
}
