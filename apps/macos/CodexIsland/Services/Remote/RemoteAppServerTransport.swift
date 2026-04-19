//
//  RemoteAppServerTransport.swift
//  CodexIsland
//
//  Process stdio transport abstraction for local and remote app-server connections.
//

import Foundation
import os.log

/// Line-oriented app-server transport used by both local and SSH-backed
/// connections. Implementations are responsible for surfacing stdout, stderr,
/// and process termination as separate signals to the monitor layer.
nonisolated protocol RemoteAppServerTransport: Sendable {
    func start(
        onStdoutLine: @escaping @Sendable (String) async -> Void,
        onStderrLine: @escaping @Sendable (String) async -> Void,
        onTermination: @escaping @Sendable (Int32) async -> Void
    ) async throws
    func send(line: String) async throws
    func stop() async
}

/// Launches a child process and exposes its stdio as newline-delimited async
/// callbacks. The monitor owns higher-level protocol framing; this type only
/// guarantees byte transport and lifecycle notifications.
final class ProcessStdioTransport: RemoteAppServerTransport, @unchecked Sendable {
    nonisolated private static let logger = Logger(subsystem: "com.codexisland", category: "RemoteTransport")

    private let executableURL: URL
    private let arguments: [String]
    private let ioQueue: DispatchQueue

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()

    nonisolated init(
        executableURL: URL,
        arguments: [String],
        queueLabel: String = "com.codexisland.remote-transport"
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.ioQueue = DispatchQueue(label: queueLabel, qos: .userInitiated)
    }

    func start(
        onStdoutLine: @escaping @Sendable (String) async -> Void,
        onStderrLine: @escaping @Sendable (String) async -> Void,
        onTermination: @escaping @Sendable (Int32) async -> Void
    ) async throws {
        // Multiple callers may race to reconnect; once a process exists we keep
        // the original pipes alive and treat later `start` calls as no-ops.
        guard process == nil else { return }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { terminatedProcess in
            Task {
                // Termination is reported independently from stdout/stderr EOF.
                // Callers should expect the last buffered lines to arrive before
                // or after this callback depending on OS scheduling.
                await onTermination(terminatedProcess.terminationStatus)
            }
        }

        try process.run()
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        configureNoSIGPIPE(for: stdinPipe.fileHandleForWriting)
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
        do {
            try stdinHandle.write(contentsOf: data)
            try stdinHandle.write(contentsOf: Data([0x0A]))
        } catch {
            Self.logger.error("Failed to write app-server stdin: \(error.localizedDescription, privacy: .public)")
            throw RemoteSessionError.transport("Failed to send app-server message: \(error.localizedDescription)")
        }
    }

    func stop() async {
        stopReaders()
        stdoutBuffer.removeAll(keepingCapacity: false)
        stderrBuffer.removeAll(keepingCapacity: false)

        closeStdinHandle()
        terminateProcessIfNeeded()
    }

    private func startReaders(
        stdout: FileHandle,
        stderr: FileHandle,
        onStdoutLine: @escaping @Sendable (String) async -> Void,
        onStderrLine: @escaping @Sendable (String) async -> Void
    ) {
        let stdoutSource = DispatchSource.makeReadSource(fileDescriptor: stdout.fileDescriptor, queue: ioQueue)
        stdoutSource.setEventHandler { [weak self] in
            self?.drainStdout(handle: stdout, forward: onStdoutLine)
        }
        stdoutSource.setCancelHandler {
            Self.closeReadHandle(stdout, label: "stdout")
        }
        stdoutSource.resume()
        self.stdoutSource = stdoutSource

        let stderrSource = DispatchSource.makeReadSource(fileDescriptor: stderr.fileDescriptor, queue: ioQueue)
        stderrSource.setEventHandler { [weak self] in
            self?.drainStderr(handle: stderr, forward: onStderrLine)
        }
        stderrSource.setCancelHandler {
            Self.closeReadHandle(stderr, label: "stderr")
        }
        stderrSource.resume()
        self.stderrSource = stderrSource
    }

    private func configureNoSIGPIPE(for handle: FileHandle) {
        // Broken pipes should be reported as write failures, not crash the app
        // when the remote/local app-server exits before stdin is flushed.
        let result = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        if result == -1 {
            let message = String(cString: strerror(errno))
            Self.logger.error("Failed to configure F_SETNOSIGPIPE: \(message, privacy: .public)")
        }
    }

    private func drainStdout(
        handle: FileHandle,
        forward: @escaping @Sendable (String) async -> Void
    ) {
        drain(handle: handle, buffer: &stdoutBuffer, forward: forward)
    }

    private func drainStderr(
        handle: FileHandle,
        forward: @escaping @Sendable (String) async -> Void
    ) {
        drain(handle: handle, buffer: &stderrBuffer, forward: forward)
    }

    private func drain(
        handle: FileHandle,
        buffer: inout Data,
        forward: @escaping @Sendable (String) async -> Void
    ) {
        let data = handle.availableData
        guard !data.isEmpty else {
            // EOF can arrive without a trailing newline. Flush the residual
            // bytes once so stderr diagnostics or the final JSON line are not
            // silently dropped on clean shutdown.
            flushResidualBuffer(&buffer, forward: forward)
            return
        }

        buffer.append(data)
        let newline = Data([0x0A])

        while let range = buffer.range(of: newline) {
            let lineData = buffer.subdata(in: buffer.startIndex ..< range.lowerBound)
            buffer.removeSubrange(buffer.startIndex ..< range.upperBound)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            Task {
                await forward(line)
            }
        }
    }

    private func flushResidualBuffer(
        _ buffer: inout Data,
        forward: @escaping @Sendable (String) async -> Void
    ) {
        guard !buffer.isEmpty else { return }
        defer { buffer.removeAll(keepingCapacity: false) }

        guard let line = String(data: buffer, encoding: .utf8)?
            .trimmingCharacters(in: .newlines),
            !line.isEmpty else {
            return
        }

        Task {
            await forward(line)
        }
    }

    private func stopReaders() {
        // Cancel readers first so no more callbacks race with teardown while
        // stdin/process are being closed underneath them.
        stdoutSource?.cancel()
        stderrSource?.cancel()
        stdoutSource = nil
        stderrSource = nil
    }

    private func closeStdinHandle() {
        guard let stdinHandle else { return }
        defer { self.stdinHandle = nil }

        do {
            try stdinHandle.close()
        } catch {
            Self.logger.error("Failed to close stdin handle: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func terminateProcessIfNeeded() {
        guard let process else { return }
        defer { self.process = nil }

        if process.isRunning {
            process.terminate()
        }
    }

    nonisolated private static func closeReadHandle(_ handle: FileHandle, label: String) {
        do {
            try handle.close()
        } catch {
            logger.error("Failed to close \(label, privacy: .public) handle: \(error.localizedDescription, privacy: .public)")
        }
    }
}

final class SSHStdioTransport: RemoteAppServerTransport, @unchecked Sendable {
    private let transport: ProcessStdioTransport

    nonisolated init(host: RemoteHostConfig) {
        // `-T` disables tty allocation so the remote app-server speaks raw
        // stdio/JSONL without shell prompt or line-editing interference.
        self.transport = ProcessStdioTransport(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: Self.sshArguments(host: host),
            queueLabel: "com.codexisland.remote-ssh-transport"
        )
    }

    nonisolated static func sshArguments(host: RemoteHostConfig) -> [String] {
        var arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            host.sshTarget,
            "codex"
        ]

        let defaultCwd = host.defaultCwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if !defaultCwd.isEmpty {
            arguments.append(contentsOf: ["--cd", defaultCwd])
        }

        arguments.append(contentsOf: ["app-server", "--listen", "stdio://"])
        return arguments
    }

    func start(
        onStdoutLine: @escaping @Sendable (String) async -> Void,
        onStderrLine: @escaping @Sendable (String) async -> Void,
        onTermination: @escaping @Sendable (Int32) async -> Void
    ) async throws {
        try await transport.start(
            onStdoutLine: onStdoutLine,
            onStderrLine: onStderrLine,
            onTermination: onTermination
        )
    }

    func send(line: String) async throws {
        try await transport.send(line: line)
    }

    func stop() async {
        await transport.stop()
    }
}

final class LocalCodexAppServerTransport: RemoteAppServerTransport, @unchecked Sendable {
    private let transport: ProcessStdioTransport

    nonisolated init() {
        let launchConfiguration = Self.localLaunchConfiguration()
        // Local mode reuses the same transport contract so higher layers can
        // switch between local and SSH sessions without protocol branches.
        self.transport = ProcessStdioTransport(
            executableURL: launchConfiguration.executableURL,
            arguments: launchConfiguration.arguments,
            queueLabel: "com.codexisland.local-app-server-transport"
        )
    }

    nonisolated static func localLaunchConfiguration(
        shellPath: String? = Foundation.ProcessInfo.processInfo.environment["SHELL"]
    ) -> (executableURL: URL, arguments: [String]) {
        let fallbackShell = "/bin/zsh"
        let candidateShell = shellPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedShell: String
        if let candidateShell,
           !candidateShell.isEmpty,
           FileManager.default.isExecutableFile(atPath: candidateShell) {
            resolvedShell = candidateShell
        } else {
            resolvedShell = fallbackShell
        }

        // GUI-launched apps often inherit a stripped PATH, so local app-server
        // startup goes through a login shell to resolve the user's real `codex`
        // binary location before `exec`-ing into stdio mode.
        return (
            executableURL: URL(fileURLWithPath: resolvedShell),
            arguments: [
                "-lc",
                Self.localAppServerCommand()
            ]
        )
    }

    nonisolated static func localAppServerCommand() -> String {
        "exec codex app-server --listen stdio://"
    }

    func start(
        onStdoutLine: @escaping @Sendable (String) async -> Void,
        onStderrLine: @escaping @Sendable (String) async -> Void,
        onTermination: @escaping @Sendable (Int32) async -> Void
    ) async throws {
        try await transport.start(
            onStdoutLine: onStdoutLine,
            onStderrLine: onStderrLine,
            onTermination: onTermination
        )
    }

    func send(line: String) async throws {
        try await transport.send(line: line)
    }

    func stop() async {
        await transport.stop()
    }
}
