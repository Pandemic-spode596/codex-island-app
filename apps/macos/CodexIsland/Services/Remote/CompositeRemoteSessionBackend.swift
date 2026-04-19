//
//  CompositeRemoteSessionBackend.swift
//  CodexIsland
//
//  Combines legacy SSH remote hosts with shared-engine-backed local app-server routing.
//

import Combine
import Foundation

@MainActor
final class CompositeRemoteSessionBackend: ObservableObject, RemoteSessionControlling {
    @Published private(set) var hosts: [RemoteHostConfig] = []
    @Published private(set) var threads: [RemoteThreadState] = []
    @Published private(set) var hostStates: [String: RemoteHostConnectionState] = [:]
    @Published private(set) var hostActionErrors: [String: String] = [:]
    @Published private(set) var hostActionInProgress: Set<String> = []

    private let primary: any RemoteSessionControlling
    private let secondary: any RemoteSessionControlling
    private let secondaryHostIDs: Set<String>
    private var cancellables = Set<AnyCancellable>()

    private var primaryHosts: [RemoteHostConfig] = []
    private var secondaryHosts: [RemoteHostConfig] = []
    private var primaryThreads: [RemoteThreadState] = []
    private var secondaryThreads: [RemoteThreadState] = []
    private var primaryHostStates: [String: RemoteHostConnectionState] = [:]
    private var secondaryHostStates: [String: RemoteHostConnectionState] = [:]
    private var primaryHostActionErrors: [String: String] = [:]
    private var secondaryHostActionErrors: [String: String] = [:]
    private var primaryHostActionInProgress: Set<String> = []
    private var secondaryHostActionInProgress: Set<String> = []

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

    init(
        primary: any RemoteSessionControlling,
        secondary: any RemoteSessionControlling,
        secondaryHostIDs: Set<String> = []
    ) {
        self.primary = primary
        self.secondary = secondary
        self.secondaryHostIDs = secondaryHostIDs

        bindPrimaryPublishers()
        bindSecondaryPublishers()
    }

    func startMonitoring() {
        primary.startMonitoring()
        secondary.startMonitoring()
    }

    func createThread(hostId: String, onSuccess: @escaping @MainActor (RemoteThreadState) -> Void) {
        backend(forHostID: hostId).createThread(hostId: hostId, onSuccess: onSuccess)
    }

    func refreshHost(id: String) {
        backend(forHostID: id).refreshHost(id: id)
    }

    func refreshHostNow(id: String) async throws {
        try await backend(forHostID: id).refreshHostNow(id: id)
    }

    func listModels(hostId: String, includeHidden: Bool) async throws -> [RemoteAppServerModel] {
        try await backend(forHostID: hostId).listModels(hostId: hostId, includeHidden: includeHidden)
    }

    func listCollaborationModes(hostId: String) async throws -> [RemoteAppServerCollaborationModeMask] {
        try await backend(forHostID: hostId).listCollaborationModes(hostId: hostId)
    }

    func addHost() {
        primary.addHost()
    }

    func updateHost(_ host: RemoteHostConfig) {
        backend(forHostID: host.id).updateHost(host)
    }

    func removeHost(id: String) {
        backend(forHostID: id).removeHost(id: id)
    }

    func connectHost(id: String) {
        backend(forHostID: id).connectHost(id: id)
    }

    func disconnectHost(id: String) {
        backend(forHostID: id).disconnectHost(id: id)
    }

    func startThread(hostId: String) async throws -> RemoteThreadState {
        try await backend(forHostID: hostId).startThread(hostId: hostId)
    }

    func startFreshThread(hostId: String) async throws -> RemoteThreadState {
        try await backend(forHostID: hostId).startFreshThread(hostId: hostId)
    }

    func startFreshThread(hostId: String, defaultCwd: String) async throws -> RemoteThreadState {
        try await backend(forHostID: hostId).startFreshThread(hostId: hostId, defaultCwd: defaultCwd)
    }

    func openThread(hostId: String, threadId: String) async throws -> RemoteThreadState {
        try await backend(forHostID: hostId).openThread(hostId: hostId, threadId: threadId)
    }

    func sendMessage(thread: RemoteThreadState, text: String) async throws {
        try await backend(forHostID: thread.hostId).sendMessage(thread: thread, text: text)
    }

    func setTurnContext(
        thread: RemoteThreadState,
        turnContext desiredTurnContext: RemoteThreadTurnContext,
        synchronizeThread: Bool
    ) async throws -> RemoteThreadState {
        try await backend(forHostID: thread.hostId).setTurnContext(
            thread: thread,
            turnContext: desiredTurnContext,
            synchronizeThread: synchronizeThread
        )
    }

    func interrupt(thread: RemoteThreadState) async throws {
        try await backend(forHostID: thread.hostId).interrupt(thread: thread)
    }

    func approve(thread: RemoteThreadState) async throws {
        try await backend(forHostID: thread.hostId).approve(thread: thread)
    }

    func deny(thread: RemoteThreadState) async throws {
        try await backend(forHostID: thread.hostId).deny(thread: thread)
    }

    func respond(thread: RemoteThreadState, action: PendingApprovalAction) async throws {
        try await backend(forHostID: thread.hostId).respond(thread: thread, action: action)
    }

    func respond(
        thread: RemoteThreadState,
        interaction: PendingUserInputInteraction,
        answers: PendingInteractionAnswerPayload
    ) async throws {
        try await backend(forHostID: thread.hostId).respond(
            thread: thread,
            interaction: interaction,
            answers: answers
        )
    }

    func availableThreads(hostId: String, excluding threadId: String?) -> [RemoteThreadState] {
        backend(forHostID: hostId).availableThreads(hostId: hostId, excluding: threadId)
    }

    func findThread(hostId: String, threadId: String?, transcriptPath: String?) -> RemoteThreadState? {
        backend(forHostID: hostId).findThread(
            hostId: hostId,
            threadId: threadId,
            transcriptPath: transcriptPath
        )
    }

    func appendLocalInfoMessage(thread: RemoteThreadState, message: String) {
        backend(forHostID: thread.hostId).appendLocalInfoMessage(thread: thread, message: message)
    }

    private func bindPrimaryPublishers() {
        primary.hostsPublisher
            .sink { [weak self] value in
                self?.primaryHosts = value
                self?.rebuildProjection()
            }
            .store(in: &cancellables)

        primary.threadsPublisher
            .sink { [weak self] value in
                self?.primaryThreads = value
                self?.rebuildProjection()
            }
            .store(in: &cancellables)

        primary.hostStatesPublisher
            .sink { [weak self] value in
                self?.primaryHostStates = value
                self?.rebuildProjection()
            }
            .store(in: &cancellables)

        primary.hostActionErrorsPublisher
            .sink { [weak self] value in
                self?.primaryHostActionErrors = value
                self?.rebuildProjection()
            }
            .store(in: &cancellables)

        primary.hostActionInProgressPublisher
            .sink { [weak self] value in
                self?.primaryHostActionInProgress = value
                self?.rebuildProjection()
            }
            .store(in: &cancellables)
    }

    private func bindSecondaryPublishers() {
        secondary.hostsPublisher
            .sink { [weak self] value in
                self?.secondaryHosts = value
                self?.rebuildProjection()
            }
            .store(in: &cancellables)

        secondary.threadsPublisher
            .sink { [weak self] value in
                self?.secondaryThreads = value
                self?.rebuildProjection()
            }
            .store(in: &cancellables)

        secondary.hostStatesPublisher
            .sink { [weak self] value in
                self?.secondaryHostStates = value
                self?.rebuildProjection()
            }
            .store(in: &cancellables)

        secondary.hostActionErrorsPublisher
            .sink { [weak self] value in
                self?.secondaryHostActionErrors = value
                self?.rebuildProjection()
            }
            .store(in: &cancellables)

        secondary.hostActionInProgressPublisher
            .sink { [weak self] value in
                self?.secondaryHostActionInProgress = value
                self?.rebuildProjection()
            }
            .store(in: &cancellables)
    }

    private func rebuildProjection() {
        hosts = mergeHosts(primaryHosts, secondaryHosts)
        threads = mergeThreads(primaryThreads, secondaryThreads)
        hostStates = primaryHostStates.merging(secondaryHostStates) { _, secondary in secondary }
        hostActionErrors = primaryHostActionErrors.merging(secondaryHostActionErrors) { _, secondary in secondary }
        hostActionInProgress = primaryHostActionInProgress.union(secondaryHostActionInProgress)
    }

    private func backend(forHostID hostID: String) -> any RemoteSessionControlling {
        if secondaryHostIDs.contains(hostID) ||
            secondaryHosts.contains(where: { $0.id == hostID }) ||
            secondaryThreads.contains(where: { $0.hostId == hostID }) {
            return secondary
        }
        return primary
    }

    private func mergeHosts(_ primary: [RemoteHostConfig], _ secondary: [RemoteHostConfig]) -> [RemoteHostConfig] {
        var merged = primary
        let existingIDs = Set(primary.map(\.id))
        for host in secondary where !existingIDs.contains(host.id) {
            merged.append(host)
        }
        return merged
    }

    private func mergeThreads(_ primary: [RemoteThreadState], _ secondary: [RemoteThreadState]) -> [RemoteThreadState] {
        var merged = primary
        let existingStableIDs = Set(primary.map(\.stableId))
        for thread in secondary where !existingStableIDs.contains(thread.stableId) {
            merged.append(thread)
        }
        return merged
    }
}

@MainActor
enum SharedEngineRemoteSessionBackendRegistry {
    static let localAppServer = SharedEngineRemoteSessionBackend(
        localHost: CodexSessionMonitor.localAppServerHost
    )
}
