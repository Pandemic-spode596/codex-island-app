//
//  LocalHostdTransport.swift
//  CodexIsland
//
//  Local hostd process bootstrap and websocket transport for shared-engine migration.
//

import Foundation

@MainActor
final class BundledHostdProcess {
    private var process: Process?

    func start(bindAddress: String, stateDirectory: URL) throws {
        guard process == nil else { return }
        let executableURL = try Self.hostdExecutableURL()

        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "serve",
            bindAddress,
            "/bin/zsh",
            stateDirectory.path
        ]
        try process.run()
        self.process = process
    }

    func stop() {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
        }
        self.process = nil
    }

    private static func hostdExecutableURL() throws -> URL {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Engine", isDirectory: true)
            .appendingPathComponent("codex-island-hostd"),
            FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        throw RemoteSessionError.transport("Bundled codex-island-hostd is missing")
    }
}

@MainActor
final class LocalHostdWebSocketTransport: NSObject {
    private let url: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var onMessage: ((String) -> Void)?
    private var onDisconnect: ((String?) -> Void)?

    init(url: URL) {
        self.url = url
        self.session = URLSession(configuration: .default)
        super.init()
    }

    func connect(
        onMessage: @escaping (String) -> Void,
        onDisconnect: @escaping (String?) -> Void
    ) {
        guard task == nil else { return }
        self.onMessage = onMessage
        self.onDisconnect = onDisconnect
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveNext()
    }

    func send(_ text: String) async throws {
        guard let task else {
            throw RemoteSessionError.notConnected
        }
        try await task.send(.string(text))
    }

    func disconnect(reason: String? = nil) {
        task?.cancel(with: .goingAway, reason: reason?.data(using: .utf8))
        task = nil
    }

    private func receiveNext() {
        task?.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.onMessage?(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.onMessage?(text)
                        }
                    @unknown default:
                        break
                    }
                    self.receiveNext()
                case .failure(let error):
                    self.task = nil
                    self.onDisconnect?(error.localizedDescription)
                }
            }
        }
    }
}
