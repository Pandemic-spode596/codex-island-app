import Foundation
import XCTest
@testable import Codex_Island

final class RemoteAppServerTransportTests: XCTestCase {
    func testProcessTransportFlushesResidualStdoutAndStderrOnEOF() async throws {
        let recorder = LineRecorder()
        let terminated = expectation(description: "process terminated")
        let transport = ProcessStdioTransport(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'stdout-no-newline'; printf 'stderr-no-newline' >&2"]
        )

        try await transport.start(
            onStdoutLine: { line in
                await recorder.appendStdout(line)
            },
            onStderrLine: { line in
                await recorder.appendStderr(line)
            },
            onTermination: { _ in
                terminated.fulfill()
            }
        )

        await fulfillment(of: [terminated], timeout: 2)
        try await waitUntil {
            let stdout = await recorder.stdoutLines()
            let stderr = await recorder.stderrLines()
            return stdout == ["stdout-no-newline"] && stderr == ["stderr-no-newline"]
        }

        await transport.stop()
    }

    func testProcessTransportSendAfterStopThrowsNotConnected() async throws {
        let transport = ProcessStdioTransport(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: []
        )

        try await transport.start(
            onStdoutLine: { _ in },
            onStderrLine: { _ in },
            onTermination: { _ in }
        )
        await transport.stop()

        do {
            try await transport.send(line: "ping")
            XCTFail("Expected send to fail after stop")
        } catch let error as RemoteSessionError {
            guard case .notConnected = error else {
                XCTFail("Expected notConnected, got \(error)")
                return
            }
        }
    }
}

private actor LineRecorder {
    private var stdout: [String] = []
    private var stderr: [String] = []

    func appendStdout(_ line: String) {
        stdout.append(line)
    }

    func appendStderr(_ line: String) {
        stderr.append(line)
    }

    func stdoutLines() -> [String] {
        stdout
    }

    func stderrLines() -> [String] {
        stderr
    }
}
