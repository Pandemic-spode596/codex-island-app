//
//  RemoteAppServerTransport.swift
//  CodexIsland
//
//  SSH stdio transport abstraction for remote app-server connections.
//

import Foundation

protocol RemoteAppServerTransport: Sendable {
    func start(
        onStdoutLine: @escaping @Sendable (String) async -> Void,
        onStderrLine: @escaping @Sendable (String) async -> Void,
        onTermination: @escaping @Sendable (Int32) async -> Void
    ) async throws
    func send(line: String) async throws
    func stop() async
}

final class SSHStdioTransport: RemoteAppServerTransport, @unchecked Sendable {
    private let host: RemoteHostConfig
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?

    init(host: RemoteHostConfig) {
        self.host = host
    }

    func start(
        onStdoutLine: @escaping @Sendable (String) async -> Void,
        onStderrLine: @escaping @Sendable (String) async -> Void,
        onTermination: @escaping @Sendable (Int32) async -> Void
    ) async throws {
        guard process == nil else { return }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            host.sshTarget,
            "codex", "app-server", "--listen", "stdio://"
        ]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { terminatedProcess in
            Task {
                await onTermination(terminatedProcess.terminationStatus)
            }
        }

        try process.run()
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        startReaders(
            stdout: stdoutPipe.fileHandleForReading,
            stderr: stderrPipe.fileHandleForReading,
            onStdoutLine: onStdoutLine,
            onStderrLine: onStderrLine
        )
    }

    func send(line: String) async throws {
        guard let stdinHandle else {
            throw RemoteSessionError.notConnected
        }
        guard let data = line.data(using: .utf8) else {
            throw RemoteSessionError.transport("Failed to encode app-server message")
        }
        try stdinHandle.write(contentsOf: data)
        try stdinHandle.write(contentsOf: Data([0x0A]))
    }

    func stop() async {
        stdoutTask?.cancel()
        stderrTask?.cancel()
        stdoutTask = nil
        stderrTask = nil

        try? stdinHandle?.close()
        stdinHandle = nil

        if let process {
            if process.isRunning {
                process.terminate()
            }
            self.process = nil
        }
    }

    private func startReaders(
        stdout: FileHandle,
        stderr: FileHandle,
        onStdoutLine: @escaping @Sendable (String) async -> Void,
        onStderrLine: @escaping @Sendable (String) async -> Void
    ) {
        stdoutTask = Task {
            do {
                for try await line in stdout.bytes.lines {
                    await onStdoutLine(String(line))
                }
            } catch {
                return
            }
        }

        stderrTask = Task {
            do {
                for try await line in stderr.bytes.lines {
                    await onStderrLine(String(line))
                }
            } catch {
                return
            }
        }
    }
}
