import XCTest
@testable import Codex_Island

final class ProcessExecutorTests: XCTestCase {
    // 同时灌满 stdout / stderr，用来卡住“串行 drain 两条 pipe”这类真实死锁回归。
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

    // Result 断言集中在这里，避免每个测试都重复展开 failure 分支。
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
