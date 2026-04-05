import XCTest
@testable import Codex_Island

final class ProcessExecutorTests: XCTestCase {
    func testRunWithResultHandlesLargeStdoutAndStderrWithoutDeadlock() async throws {
        let script = """
        import sys
        sys.stdout.write("O" * (1024 * 1024))
        sys.stdout.flush()
        sys.stderr.write("E" * (1024 * 1024))
        sys.stderr.flush()
        """

        let result = await ProcessExecutor.shared.runWithResult(
            pythonPath,
            arguments: ["-c", script]
        )

        let processResult = try XCTUnwrap(successValue(from: result))
        XCTAssertEqual(processResult.exitCode, 0)
        XCTAssertEqual(processResult.output.count, 1024 * 1024)
        XCTAssertEqual(processResult.stderr?.count, 1024 * 1024)
    }

    func testRunSyncHandlesLargeStdoutAndStderrWithoutDeadlock() throws {
        let script = """
        import sys
        sys.stdout.write("O" * (1024 * 1024))
        sys.stdout.flush()
        sys.stderr.write("E" * (1024 * 1024))
        sys.stderr.flush()
        """

        let result = ProcessExecutor.shared.runSync(
            pythonPath,
            arguments: ["-c", script]
        )

        let output = try XCTUnwrap(successValue(from: result))
        XCTAssertEqual(output.count, 1024 * 1024)
    }

    private var pythonPath: String {
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") {
            return "/usr/bin/python3"
        }
        return "/usr/bin/python"
    }

    private func successValue<T>(from result: Result<T, ProcessExecutorError>) -> T? {
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            XCTFail("Expected success but got error: \(error.localizedDescription)")
            return nil
        }
    }
}
