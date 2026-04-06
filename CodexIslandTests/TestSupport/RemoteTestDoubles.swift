import XCTest
@testable import Codex_Island

// 测试里的远端链路经常只关心“记录到了什么日志”，这个 logger 保持最小可观察面。
actor TestDiagnosticsLogger: RemoteDiagnosticsLogging {
    private(set) var records: [RemoteDiagnosticsRecord] = []

    func log(_ record: RemoteDiagnosticsRecord) async {
        records.append(record)
    }
}

// 轻量 transport double：允许测试按需手动推送 stdout / stderr / termination 事件。
actor TestTransport: RemoteAppServerTransport {
    private var stdoutHandler: (@Sendable (String) async -> Void)?
    private var stderrHandler: (@Sendable (String) async -> Void)?
    private var terminationHandler: (@Sendable (Int32) async -> Void)?

    private(set) var sentLines: [String] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(
        onStdoutLine: @escaping @Sendable (String) async -> Void,
        onStderrLine: @escaping @Sendable (String) async -> Void,
        onTermination: @escaping @Sendable (Int32) async -> Void
    ) async throws {
        startCount += 1
        stdoutHandler = onStdoutLine
        stderrHandler = onStderrLine
        terminationHandler = onTermination
    }

    func send(line: String) async throws {
        sentLines.append(line)
    }

    func stop() async {
        stopCount += 1
    }

    func emitStdout(_ line: String) async {
        await stdoutHandler?(line)
    }

    func emitStderr(_ line: String) async {
        await stderrHandler?(line)
    }

    func terminate(exitCode: Int32) async {
        await terminationHandler?(exitCode)
    }
}

// 多数远端单测只需要 stub 出进程结果，不需要真的启动 ssh / codex 子进程。
struct TestProcessExecutor: ProcessExecuting {
    var runHandler: @Sendable (String, [String]) async throws -> String = { _, _ in "" }
    var runWithResultHandler: @Sendable (String, [String]) async -> Result<ProcessResult, ProcessExecutorError> = { _, _ in
        .success(ProcessResult(output: "", exitCode: 0, stderr: nil))
    }
    var runSyncHandler: @Sendable (String, [String]) -> Result<String, ProcessExecutorError> = { _, _ in
        .success("")
    }

    func run(_ executable: String, arguments: [String]) async throws -> String {
        try await runHandler(executable, arguments)
    }

    func runWithResult(_ executable: String, arguments: [String]) async -> Result<ProcessResult, ProcessExecutorError> {
        await runWithResultHandler(executable, arguments)
    }

    func runSync(_ executable: String, arguments: [String]) -> Result<String, ProcessExecutorError> {
        runSyncHandler(executable, arguments)
    }
}

// 统一记录 RemoteAppServerConnection 发出的事件，供测试按连接状态断言。
actor RemoteEventRecorder {
    private(set) var events: [RemoteConnectionEvent] = []

    func append(_ event: RemoteConnectionEvent) {
        events.append(event)
    }

    func connectionStates() -> [RemoteHostConnectionState] {
        events.compactMap {
            if case .connectionState(_, let state) = $0 {
                return state
            }
            return nil
        }
    }
}

// 某些 monitor 需要在异步用例里额外 retain，避免测试过早释放对象导致假阴性。
enum TestObjectRetainer {
    private static var retainedObjects: [AnyObject] = []

    static func retain(_ object: AnyObject) {
        retainedObjects.append(object)
    }

    static func reset() {
        retainedObjects.removeAll()
    }
}

// FakeRemoteConnection 让测试按需拼装 thread/start、respond、refresh 等单个能力，不必走完整协议栈。
final class FakeRemoteConnection: RemoteAppServerConnectionProtocol, @unchecked Sendable {
    var emit: (@Sendable (RemoteConnectionEvent) async -> Void)?
    var startThreadHandler: (@Sendable (String) async throws -> RemoteAppServerThreadStartResponse)?
    var resumeThreadHandler: (@Sendable (String, RemoteThreadTurnContext?) async throws -> RemoteAppServerThreadResumeResponse)?
    var sendMessageHandler: (@Sendable (String, String, String?, RemoteThreadTurnContext) async throws -> Void)?
    var interruptHandler: (@Sendable (String, String) async throws -> Void)?
    var respondHandler: (@Sendable (RemotePendingApproval, Bool) async throws -> Void)?
    var respondActionHandler: (@Sendable (RemotePendingApproval, PendingApprovalAction) async throws -> Void)?
    var respondUserInputHandler: (@Sendable (PendingUserInputInteraction, PendingInteractionAnswerPayload) async throws -> Void)?
    var refreshThreadsHandler: (@Sendable () async throws -> Void)?
    var listModelsHandler: (@Sendable (Bool) async throws -> [RemoteAppServerModel])?
    var listCollaborationModesHandler: (@Sendable () async throws -> [RemoteAppServerCollaborationModeMask])?
    var transcriptSnapshotHandler: (@Sendable (String, String, Int) async throws -> RemoteTranscriptFallbackSnapshot?)?

    private(set) var startCalled = false
    private(set) var stopCalled = false

    func updateHost(_ host: RemoteHostConfig) async {}

    func start() async {
        startCalled = true
        if let emit {
            await emit(.connectionState(hostId: "local-app-server", state: .connected))
        }
    }

    func stop() async {
        stopCalled = true
    }

    func normalizeCwd(_ cwd: String) async throws -> String? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func resolveDisplayCwdFilter(_ cwd: String) async throws -> String? {
        try await normalizeCwd(cwd)
    }

    func startThread(defaultCwd: String) async throws -> RemoteAppServerThreadStartResponse {
        guard let startThreadHandler else {
            fatalError("startThreadHandler not configured")
        }
        return try await startThreadHandler(defaultCwd)
    }

    func resumeThread(
        threadId: String,
        turnContext: RemoteThreadTurnContext?
    ) async throws -> RemoteAppServerThreadResumeResponse {
        guard let resumeThreadHandler else {
            fatalError("resumeThreadHandler not configured")
        }
        return try await resumeThreadHandler(threadId, turnContext)
    }

    func sendMessage(
        threadId: String,
        text: String,
        activeTurnId: String?,
        turnContext: RemoteThreadTurnContext
    ) async throws {
        try await sendMessageHandler?(threadId, text, activeTurnId, turnContext)
    }

    func interrupt(threadId: String, turnId: String) async throws {
        try await interruptHandler?(threadId, turnId)
    }

    func respond(to approval: RemotePendingApproval, allow: Bool) async throws {
        try await respondHandler?(approval, allow)
    }

    func respond(to approval: RemotePendingApproval, action: PendingApprovalAction) async throws {
        if let respondActionHandler {
            try await respondActionHandler(approval, action)
            return
        }
        try await respondHandler?(approval, action == .allow)
    }

    func respond(to interaction: PendingUserInputInteraction, answers: PendingInteractionAnswerPayload) async throws {
        try await respondUserInputHandler?(interaction, answers)
    }

    func refreshThreads() async throws {
        try await refreshThreadsHandler?()
    }

    func listModels(includeHidden: Bool) async throws -> [RemoteAppServerModel] {
        try await listModelsHandler?(includeHidden) ?? []
    }

    func listCollaborationModes() async throws -> [RemoteAppServerCollaborationModeMask] {
        try await listCollaborationModesHandler?() ?? []
    }

    func loadTranscriptFallbackSnapshot(
        sessionId: String,
        transcriptPath: String,
        maxLines: Int
    ) async throws -> RemoteTranscriptFallbackSnapshot? {
        try await transcriptSnapshotHandler?(sessionId, transcriptPath, maxLines)
    }
}

// 统一的线程夹具，避免每个测试都手写一份最小 thread payload。
func makeThread(
    id: String = "thread-1",
    preview: String = "Preview",
    status: RemoteAppServerThreadStatus = .idle,
    turns: [RemoteAppServerTurn] = [],
    cwd: String = "/tmp",
    path: String? = nil,
    name: String? = nil
) -> RemoteAppServerThread {
    RemoteAppServerThread(
        id: id,
        preview: preview,
        ephemeral: false,
        modelProvider: "openai",
        createdAt: 1_700_000_000,
        updatedAt: 1_700_000_100,
        status: status,
        path: path,
        cwd: cwd,
        cliVersion: "1.0.0",
        name: name,
        turns: turns
    )
}

// thread/start 响应经常要补一组默认策略字段，这里集中提供稳定夹具。
func makeThreadStartResponse(
    thread: RemoteAppServerThread,
    model: String = "gpt-5.4",
    modelProvider: String = "openai",
    serviceTier: RemoteAppServerServiceTier? = nil,
    cwd: String = "/tmp",
    approvalPolicy: RemoteAppServerApprovalPolicy = .onRequest,
    approvalsReviewer: RemoteAppServerApprovalsReviewer = .user,
    sandbox: RemoteAppServerSandboxPolicy = .workspaceWrite(),
    reasoningEffort: RemoteAppServerReasoningEffort? = .medium,
    collaborationMode: RemoteAppServerCollaborationMode? = nil
) -> RemoteAppServerThreadStartResponse {
    RemoteAppServerThreadStartResponse(
        thread: thread,
        model: model,
        modelProvider: modelProvider,
        serviceTier: serviceTier,
        cwd: cwd,
        approvalPolicy: approvalPolicy,
        approvalsReviewer: approvalsReviewer,
        sandbox: sandbox,
        reasoningEffort: reasoningEffort,
        collaborationMode: collaborationMode
    )
}

func makeThreadResumeResponse(
    thread: RemoteAppServerThread,
    model: String = "gpt-5.4",
    modelProvider: String = "openai",
    serviceTier: RemoteAppServerServiceTier? = nil,
    cwd: String = "/tmp",
    approvalPolicy: RemoteAppServerApprovalPolicy = .onRequest,
    approvalsReviewer: RemoteAppServerApprovalsReviewer = .user,
    sandbox: RemoteAppServerSandboxPolicy = .workspaceWrite(),
    reasoningEffort: RemoteAppServerReasoningEffort? = .medium,
    collaborationMode: RemoteAppServerCollaborationMode? = nil
) -> RemoteAppServerThreadResumeResponse {
    RemoteAppServerThreadResumeResponse(
        thread: thread,
        model: model,
        modelProvider: modelProvider,
        serviceTier: serviceTier,
        cwd: cwd,
        approvalPolicy: approvalPolicy,
        approvalsReviewer: approvalsReviewer,
        sandbox: sandbox,
        reasoningEffort: reasoningEffort,
        collaborationMode: collaborationMode
    )
}

func makeTurn(
    id: String = "turn-1",
    items: [RemoteAppServerThreadItem] = [],
    status: RemoteAppServerTurnStatus = .completed
) -> RemoteAppServerTurn {
    RemoteAppServerTurn(id: id, items: items, status: status, error: nil)
}

func makeEnvelopeJSON(
    id: Int? = nil,
    method: String? = nil,
    params: Any? = nil,
    result: Any? = nil,
    error: [String: Any]? = nil
) throws -> String {
    var payload: [String: Any] = [:]
    if let method {
        payload["method"] = method
    }
    if let id {
        payload["id"] = id
    }
    if let params {
        payload["params"] = params
    }
    if let result {
        payload["result"] = result
    }
    if let error {
        payload["error"] = error
    }

    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

func waitUntil(
    timeout: TimeInterval = 5.0,
    interval: UInt64 = 20_000_000,
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(nanoseconds: interval)
    }
    XCTFail("Timed out waiting for condition")
}
