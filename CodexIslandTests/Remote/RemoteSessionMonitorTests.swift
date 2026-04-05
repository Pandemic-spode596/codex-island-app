import XCTest
@testable import Codex_Island

@MainActor
final class RemoteSessionMonitorTests: XCTestCase {
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
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)
        let recoveredThread = makeThread(id: "thread-new", preview: "Recovered")

        connection.startThreadHandler = { _ in
            throw RemoteSessionError.timeout("Timed out waiting for app-server response to thread/start")
        }
        connection.refreshThreadsHandler = {
            await connection.emit?(.threadUpsert(hostId: host.id, thread: recoveredThread))
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
        let recovered = try await monitor.startThread(hostId: host.id)

        XCTAssertEqual(recovered.threadId, "thread-new")
        XCTAssertNil(monitor.hostActionErrors[host.id])
    }

    func testSendMessageAddsOptimisticUserItemOnTimeout() async throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)
        let baseThread = makeThread(id: "thread-1", preview: "Preview", status: .idle)

        connection.startThreadHandler = { _ in makeThreadStartResponse(thread: baseThread) }
        connection.sendMessageHandler = { _, _, _, _ in
            throw RemoteSessionError.timeout("Timed out waiting for app-server response to turn/start")
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
        let thread = try XCTUnwrap(monitor.threads.first)

        try await monitor.sendMessage(thread: thread, text: "hi")

        let updated = try XCTUnwrap(monitor.threads.first)
        XCTAssertEqual(updated.history.last?.type, .user("hi"))
        XCTAssertEqual(updated.phase, .processing)
    }

    func testSendMessageMergesOptimisticUserItemWhenServerUserMessageArrives() async throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)
        let baseThread = makeThread(id: "thread-1", preview: "Preview", status: .idle)

        connection.startThreadHandler = { _ in makeThreadStartResponse(thread: baseThread) }
        connection.sendMessageHandler = { _, _, _, _ in }

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
        let thread = try XCTUnwrap(monitor.threads.first)

        try await monitor.sendMessage(thread: thread, text: "hi")
        monitor.apply(event: .itemStarted(
            hostId: host.id,
            threadId: "thread-1",
            turnId: "turn-1",
            item: .userMessage(id: "server-user-1", content: [.text("hi")])
        ))

        let updated = try XCTUnwrap(monitor.threads.first)
        XCTAssertEqual(updated.history.count, 1)
        XCTAssertEqual(updated.history.first?.id, "server-user-1")
        XCTAssertEqual(updated.history.first?.type, .user("hi"))
    }

    func testSendMessageRemovesOptimisticUserItemOnFailure() async throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)
        let baseThread = makeThread(id: "thread-1", preview: "Preview", status: .idle)

        connection.sendMessageHandler = { _, _, _, _ in
            throw RemoteSessionError.transport("boom")
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
        let thread = try XCTUnwrap(monitor.threads.first)

        do {
            try await monitor.sendMessage(thread: thread, text: "hi")
            XCTFail("Expected sendMessage to fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, "boom")
        }

        let updated = try XCTUnwrap(monitor.threads.first)
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

    func testTurnPlanUpdatedAddsTodoWriteHistoryItem() throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)
        let thread = makeThread(id: "thread-1", preview: "Preview", status: .idle)

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

        monitor.apply(event: .threadUpsert(hostId: host.id, thread: thread))
        monitor.apply(event: .turnPlanUpdated(
            hostId: host.id,
            threadId: "thread-1",
            turnId: "turn-1",
            explanation: "Syncing plan",
            plan: [
                RemoteAppServerPlanStep(step: "Inspect remote state", status: "completed"),
                RemoteAppServerPlanStep(step: "Patch UI", status: "in_progress")
            ]
        ))

        let updated = try XCTUnwrap(monitor.threads.first)
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
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)
        let thread = makeThread(id: "thread-1", preview: "Preview", status: .idle)

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

        monitor.apply(event: .threadUpsert(hostId: host.id, thread: thread))
        monitor.apply(event: .tokenUsageUpdated(
            hostId: host.id,
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

        let updated = try XCTUnwrap(monitor.threads.first)
        XCTAssertEqual(updated.contextRemainingPercent, 91)
        XCTAssertEqual(updated.tokenUsage?.totalTokenUsage.totalTokens, 123_000)
    }

    func testApprovalEventSetsPendingApprovalState() throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)
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

        monitor.apply(event: .threadUpsert(hostId: host.id, thread: thread))
        monitor.apply(event: .approval(hostId: host.id, threadId: "thread-1", approval: approval))

        let updated = try XCTUnwrap(monitor.threads.first)
        XCTAssertEqual(updated.pendingApproval?.id, "approval-1")
        XCTAssertEqual(updated.phase.approvalToolName, "Command Execution")
        XCTAssertEqual(updated.pendingToolInput, "pwd")
    }

    func testUserInputRequestSetsPendingInteractionState() throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)
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

        monitor.apply(event: .threadUpsert(hostId: host.id, thread: thread))
        monitor.apply(event: .userInputRequest(hostId: host.id, threadId: "thread-1", interaction: interaction))

        let updated = try XCTUnwrap(monitor.threads.first)
        XCTAssertEqual(updated.pendingInteractions.count, 1)
        XCTAssertEqual(updated.primaryPendingInteraction?.id, "item-1")
        XCTAssertTrue(updated.needsAttention)
    }

    func testServerRequestResolvedClearsPendingInteractionState() throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)
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

        monitor.apply(event: .threadUpsert(hostId: host.id, thread: thread))
        monitor.apply(event: .userInputRequest(hostId: host.id, threadId: "thread-1", interaction: interaction))
        monitor.apply(event: .serverRequestResolved(hostId: host.id, threadId: "thread-1", requestId: .int(7)))

        let updated = try XCTUnwrap(monitor.threads.first)
        XCTAssertTrue(updated.pendingInteractions.isEmpty)
    }

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
