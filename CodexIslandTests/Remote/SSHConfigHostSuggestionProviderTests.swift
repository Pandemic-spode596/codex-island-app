import XCTest
@testable import Codex_Island

final class SSHConfigHostSuggestionProviderTests: XCTestCase {
    // 候选只接受具体 alias；wildcard 和 Include 解析都要在这里锁住，避免 UI 建议列表误导用户。
    func testLoadSuggestionsReadsConcreteHostsAndIncludeFiles() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let sshDirectory = tempDirectory.appendingPathComponent(".ssh", isDirectory: true)
        let includedDirectory = sshDirectory.appendingPathComponent("conf.d", isDirectory: true)

        try FileManager.default.createDirectory(at: includedDirectory, withIntermediateDirectories: true, attributes: nil)
        try """
        Host cd
          HostName 100.114.242.113
          User deploy

        Host *
          User fallback

        Include conf.d/*.conf

        Host staging-*
          User wildcard
        """.write(to: sshDirectory.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        try """
        Host prod
          HostName prod.example.com
          Port 2200
        """.write(to: includedDirectory.appendingPathComponent("prod.conf"), atomically: true, encoding: .utf8)

        let executor = TestProcessExecutor(
            runWithResultHandler: { executable, arguments in
                XCTAssertEqual(executable, "/usr/bin/ssh")
                XCTAssertTrue(arguments.starts(with: ["-G", "-F"]))

                let alias = arguments.last ?? ""
                switch alias {
                case "cd":
                    return .success(
                        ProcessResult(
                            output: "hostname 100.114.242.113\nuser deploy\nport 22\n",
                            exitCode: 0,
                            stderr: nil
                        )
                    )
                case "prod":
                    return .success(
                        ProcessResult(
                            output: "hostname prod.example.com\nport 2200\n",
                            exitCode: 0,
                            stderr: nil
                        )
                    )
                default:
                    return .failure(.executionFailed(command: executable, exitCode: 255, stderr: "unknown alias"))
                }
            }
        )

        let provider = SSHConfigHostSuggestionProvider(
            fileManager: .default,
            processExecutor: executor,
            configURL: sshDirectory.appendingPathComponent("config")
        )

        let suggestions = await provider.loadSuggestions()

        XCTAssertEqual(suggestions.map(\.alias), ["cd", "prod"])
        XCTAssertEqual(suggestions[0].resolutionSummary, "deploy@100.114.242.113")
        XCTAssertEqual(suggestions[1].resolutionSummary, "prod.example.com:2200")
    }

    func testLoadSuggestionsFallsBackGracefullyWhenConfigIsMissing() async {
        let missingConfigURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(".ssh/config")
        let provider = SSHConfigHostSuggestionProvider(
            fileManager: .default,
            processExecutor: TestProcessExecutor(),
            configURL: missingConfigURL
        )

        let suggestions = await provider.loadSuggestions()

        XCTAssertTrue(suggestions.isEmpty)
    }

    func testLoadSuggestionsKeepsAliasWhenResolutionFails() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let sshDirectory = tempDirectory.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true, attributes: nil)
        try """
        Host cd
          HostName 100.114.242.113
        """.write(to: sshDirectory.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        let provider = SSHConfigHostSuggestionProvider(
            fileManager: .default,
            processExecutor: TestProcessExecutor(
                runWithResultHandler: { executable, _ in
                    .failure(.executionFailed(command: executable, exitCode: 255, stderr: "boom"))
                }
            ),
            configURL: sshDirectory.appendingPathComponent("config")
        )

        let suggestions = await provider.loadSuggestions()

        XCTAssertEqual(suggestions.map(\.alias), ["cd"])
        XCTAssertNil(suggestions.first?.resolutionSummary)
    }

    // 每个测试都用独立 ssh 目录，避免 Include / config fixture 串到别的用例。
    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
