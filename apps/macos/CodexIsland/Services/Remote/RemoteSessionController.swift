//
//  RemoteSessionController.swift
//  CodexIsland
//
//  Replaceable remote/session boundary for SwiftUI and session monitors.
//

import Combine
import Foundation

@MainActor
protocol RemoteSessionControlling: AnyObject {
    var hostsPublisher: AnyPublisher<[RemoteHostConfig], Never> { get }
    var threadsPublisher: AnyPublisher<[RemoteThreadState], Never> { get }
    var hostStatesPublisher: AnyPublisher<[String: RemoteHostConnectionState], Never> { get }
    var hostActionErrorsPublisher: AnyPublisher<[String: String], Never> { get }
    var hostActionInProgressPublisher: AnyPublisher<Set<String>, Never> { get }

    func startMonitoring()
    func createThread(hostId: String, onSuccess: @escaping @MainActor (RemoteThreadState) -> Void)
    func refreshHost(id: String)
    func refreshHostNow(id: String) async throws
    func listModels(hostId: String, includeHidden: Bool) async throws -> [RemoteAppServerModel]
    func listCollaborationModes(hostId: String) async throws -> [RemoteAppServerCollaborationModeMask]
    func addHost()
    func updateHost(_ host: RemoteHostConfig)
    func removeHost(id: String)
    func connectHost(id: String)
    func disconnectHost(id: String)
    func startThread(hostId: String) async throws -> RemoteThreadState
    func startFreshThread(hostId: String) async throws -> RemoteThreadState
    func startFreshThread(hostId: String, defaultCwd: String) async throws -> RemoteThreadState
    func openThread(hostId: String, threadId: String) async throws -> RemoteThreadState
    func sendMessage(thread: RemoteThreadState, text: String) async throws
    func setTurnContext(
        thread: RemoteThreadState,
        turnContext desiredTurnContext: RemoteThreadTurnContext,
        synchronizeThread: Bool
    ) async throws -> RemoteThreadState
    func interrupt(thread: RemoteThreadState) async throws
    func approve(thread: RemoteThreadState) async throws
    func deny(thread: RemoteThreadState) async throws
    func respond(thread: RemoteThreadState, action: PendingApprovalAction) async throws
    func respond(
        thread: RemoteThreadState,
        interaction: PendingUserInputInteraction,
        answers: PendingInteractionAnswerPayload
    ) async throws
    func availableThreads(hostId: String, excluding threadId: String?) -> [RemoteThreadState]
    func findThread(hostId: String, threadId: String?, transcriptPath: String?) -> RemoteThreadState?
    func appendLocalInfoMessage(thread: RemoteThreadState, message: String)
}

@MainActor
final class RemoteSessionController: ObservableObject {
    static let shared = RemoteSessionController(
        backend: CompositeRemoteSessionBackend(
            primary: RemoteSessionMonitor.shared,
            secondary: SharedEngineRemoteSessionBackendRegistry.localAppServer,
            secondaryHostIDs: [CodexSessionMonitor.localAppServerHost.id]
        )
    )

    @Published private(set) var hosts: [RemoteHostConfig] = []
    @Published private(set) var threads: [RemoteThreadState] = []
    @Published private(set) var hostStates: [String: RemoteHostConnectionState] = [:]
    @Published private(set) var hostActionErrors: [String: String] = [:]
    @Published private(set) var hostActionInProgress: Set<String> = []

    private let backend: any RemoteSessionControlling
    private var cancellables = Set<AnyCancellable>()

    init(backend: any RemoteSessionControlling) {
        self.backend = backend

        backend.hostsPublisher
            .sink { [weak self] in self?.hosts = $0 }
            .store(in: &cancellables)

        backend.threadsPublisher
            .sink { [weak self] in self?.threads = $0 }
            .store(in: &cancellables)

        backend.hostStatesPublisher
            .sink { [weak self] in self?.hostStates = $0 }
            .store(in: &cancellables)

        backend.hostActionErrorsPublisher
            .sink { [weak self] in self?.hostActionErrors = $0 }
            .store(in: &cancellables)

        backend.hostActionInProgressPublisher
            .sink { [weak self] in self?.hostActionInProgress = $0 }
            .store(in: &cancellables)
    }

    func startMonitoring() {
        backend.startMonitoring()
    }

    func createThread(hostId: String, onSuccess: @escaping @MainActor (RemoteThreadState) -> Void) {
        backend.createThread(hostId: hostId, onSuccess: onSuccess)
    }

    func refreshHost(id: String) {
        backend.refreshHost(id: id)
    }

    func refreshHostNow(id: String) async throws {
        try await backend.refreshHostNow(id: id)
    }

    func listModels(hostId: String, includeHidden: Bool = false) async throws -> [RemoteAppServerModel] {
        try await backend.listModels(hostId: hostId, includeHidden: includeHidden)
    }

    func listCollaborationModes(hostId: String) async throws -> [RemoteAppServerCollaborationModeMask] {
        try await backend.listCollaborationModes(hostId: hostId)
    }

    func addHost() {
        backend.addHost()
    }

    func updateHost(_ host: RemoteHostConfig) {
        backend.updateHost(host)
    }

    func removeHost(id: String) {
        backend.removeHost(id: id)
    }

    func connectHost(id: String) {
        backend.connectHost(id: id)
    }

    func disconnectHost(id: String) {
        backend.disconnectHost(id: id)
    }

    func startThread(hostId: String) async throws -> RemoteThreadState {
        try await backend.startThread(hostId: hostId)
    }

    func startFreshThread(hostId: String) async throws -> RemoteThreadState {
        try await backend.startFreshThread(hostId: hostId)
    }

    func startFreshThread(hostId: String, defaultCwd: String) async throws -> RemoteThreadState {
        try await backend.startFreshThread(hostId: hostId, defaultCwd: defaultCwd)
    }

    func openThread(hostId: String, threadId: String) async throws -> RemoteThreadState {
        try await backend.openThread(hostId: hostId, threadId: threadId)
    }

    func sendMessage(thread: RemoteThreadState, text: String) async throws {
        try await backend.sendMessage(thread: thread, text: text)
    }

    func setTurnContext(
        thread: RemoteThreadState,
        turnContext desiredTurnContext: RemoteThreadTurnContext,
        synchronizeThread: Bool
    ) async throws -> RemoteThreadState {
        try await backend.setTurnContext(
            thread: thread,
            turnContext: desiredTurnContext,
            synchronizeThread: synchronizeThread
        )
    }

    func interrupt(thread: RemoteThreadState) async throws {
        try await backend.interrupt(thread: thread)
    }

    func approve(thread: RemoteThreadState) async throws {
        try await backend.approve(thread: thread)
    }

    func deny(thread: RemoteThreadState) async throws {
        try await backend.deny(thread: thread)
    }

    func respond(thread: RemoteThreadState, action: PendingApprovalAction) async throws {
        try await backend.respond(thread: thread, action: action)
    }

    func respond(
        thread: RemoteThreadState,
        interaction: PendingUserInputInteraction,
        answers: PendingInteractionAnswerPayload
    ) async throws {
        try await backend.respond(thread: thread, interaction: interaction, answers: answers)
    }

    func availableThreads(hostId: String, excluding threadId: String? = nil) -> [RemoteThreadState] {
        backend.availableThreads(hostId: hostId, excluding: threadId)
    }

    func findThread(
        hostId: String,
        threadId: String? = nil,
        transcriptPath: String? = nil
    ) -> RemoteThreadState? {
        backend.findThread(hostId: hostId, threadId: threadId, transcriptPath: transcriptPath)
    }

    func appendLocalInfoMessage(thread: RemoteThreadState, message: String) {
        backend.appendLocalInfoMessage(thread: thread, message: message)
    }
}

@MainActor
extension RemoteSessionMonitor: RemoteSessionControlling {
    var hostsPublisher: AnyPublisher<[RemoteHostConfig], Never> {
        $hosts.eraseToAnyPublisher()
    }

    var threadsPublisher: AnyPublisher<[RemoteThreadState], Never> {
        $threads.eraseToAnyPublisher()
    }

    var hostStatesPublisher: AnyPublisher<[String: RemoteHostConnectionState], Never> {
        $hostStates.eraseToAnyPublisher()
    }

    var hostActionErrorsPublisher: AnyPublisher<[String: String], Never> {
        $hostActionErrors.eraseToAnyPublisher()
    }

    var hostActionInProgressPublisher: AnyPublisher<Set<String>, Never> {
        $hostActionInProgress.eraseToAnyPublisher()
    }
}
