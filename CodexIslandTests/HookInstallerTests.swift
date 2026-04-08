import XCTest
@testable import Codex_Island

final class HookInstallerTests: XCTestCase {
    func testInstallIfNeededReplacesExistingFalseValueWithoutDuplicatingCodexHooksKey() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        let hooksDir = codexDir.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        let configToml = codexDir.appendingPathComponent("config.toml")
        let bundledScript = home.appendingPathComponent("bundled.py")

        try """
        [features]
        codex_hooks = false
        another_flag = true
        """.write(to: configToml, atomically: true, encoding: .utf8)
        try Data("new-script".utf8).write(to: bundledScript)

        try HookInstaller.installIfNeeded(
            homeDirectory: home,
            bundledScriptURL: bundledScript
        )

        let updatedConfig = try String(contentsOf: configToml, encoding: .utf8)
        XCTAssertEqual(updatedConfig.components(separatedBy: "codex_hooks").count - 1, 1)
        XCTAssertTrue(updatedConfig.contains("codex_hooks = true"))
        XCTAssertFalse(updatedConfig.contains("codex_hooks = false"))
    }

    func testInstallIfNeededPreservesNewlineAfterReplacingCodexHooksBeforeNextSection() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        let hooksDir = codexDir.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        let configToml = codexDir.appendingPathComponent("config.toml")
        let bundledScript = home.appendingPathComponent("bundled.py")

        try """
        [features]
        codex_hooks = false
        [mcp_servers.chrome-devtools]
        command = "npx"
        """.write(to: configToml, atomically: true, encoding: .utf8)
        try Data("new-script".utf8).write(to: bundledScript)

        try HookInstaller.installIfNeeded(
            homeDirectory: home,
            bundledScriptURL: bundledScript
        )

        let updatedConfig = try String(contentsOf: configToml, encoding: .utf8)
        XCTAssertTrue(updatedConfig.contains("codex_hooks = true\n[mcp_servers.chrome-devtools]"))
        XCTAssertFalse(updatedConfig.contains("codex_hooks = true[mcp_servers.chrome-devtools]"))
    }

    func testInstallIfNeededAddsCodexHooksInsideExistingFeaturesSectionWhenMissing() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        let hooksDir = codexDir.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        let configToml = codexDir.appendingPathComponent("config.toml")
        let bundledScript = home.appendingPathComponent("bundled.py")

        try """
        [features]
        another_flag = true

        [profile.dev]
        trace = false
        """.write(to: configToml, atomically: true, encoding: .utf8)
        try Data("new-script".utf8).write(to: bundledScript)

        try HookInstaller.installIfNeeded(
            homeDirectory: home,
            bundledScriptURL: bundledScript
        )

        let updatedConfig = try String(contentsOf: configToml, encoding: .utf8)
        XCTAssertEqual(updatedConfig.components(separatedBy: "codex_hooks").count - 1, 1)
        XCTAssertTrue(updatedConfig.contains("codex_hooks = true"))
        let profileSectionIndex = try XCTUnwrap(updatedConfig.range(of: "[profile.dev]")?.lowerBound)
        let codexHooksIndex = try XCTUnwrap(updatedConfig.range(of: "codex_hooks = true")?.lowerBound)
        XCTAssertLessThan(codexHooksIndex, profileSectionIndex)
        XCTAssertTrue(updatedConfig.contains("[profile.dev]\ntrace = false"))
    }

    func testInstallIfNeededRestoresOriginalFilesWhenHooksConfigIsInvalid() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        let hooksDir = codexDir.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        let existingScript = hooksDir.appendingPathComponent("codex-island-state.py")
        let hooksConfig = codexDir.appendingPathComponent("hooks.json")
        let configToml = codexDir.appendingPathComponent("config.toml")
        let bundledScript = home.appendingPathComponent("bundled.py")

        try Data("old-script".utf8).write(to: existingScript)
        try Data("not-json".utf8).write(to: hooksConfig)
        try "[features]\nother = true\n".write(to: configToml, atomically: true, encoding: .utf8)
        try Data("new-script".utf8).write(to: bundledScript)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: existingScript.path)

        XCTAssertThrowsError(
            try HookInstaller.installIfNeeded(
                homeDirectory: home,
                bundledScriptURL: bundledScript
            )
        )

        XCTAssertEqual(try String(contentsOf: existingScript, encoding: .utf8), "old-script")
        XCTAssertEqual(try String(contentsOf: configToml, encoding: .utf8), "[features]\nother = true\n")
        XCTAssertEqual(try String(contentsOf: hooksConfig, encoding: .utf8), "not-json")

        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: existingScript.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue, 0o644)
    }

    func testInstallIfNeededDoesNotCorruptTopLevelKeysWhenCodexHooksAlreadyExists() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        let hooksDir = codexDir.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        let configToml = codexDir.appendingPathComponent("config.toml")
        let bundledScript = home.appendingPathComponent("bundled.py")

        let originalConfig = """
        model_provider = "packycode"
        model = "gpt-5.4"
        model_reasonable_response_storage = true

        [features]
        unified_exec = true
        codex_hooks = false
        """
        try originalConfig.write(to: configToml, atomically: true, encoding: .utf8)
        try Data("new-script".utf8).write(to: bundledScript)

        try HookInstaller.installIfNeeded(
            homeDirectory: home,
            bundledScriptURL: bundledScript
        )

        let updatedConfig = try String(contentsOf: configToml, encoding: .utf8)
        XCTAssertTrue(updatedConfig.contains("model_reasonable_response_storage = true"))
        XCTAssertFalse(updatedConfig.contains("model_reacodex_hooks"))
        XCTAssertEqual(updatedConfig.components(separatedBy: "codex_hooks").count - 1, 1)
        XCTAssertTrue(updatedConfig.contains("codex_hooks = true"))
    }

    func testInstallIfNeededLeavesConfigUntouchedWhenCodexHooksAlreadyTrue() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        let hooksDir = codexDir.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        let configToml = codexDir.appendingPathComponent("config.toml")
        let bundledScript = home.appendingPathComponent("bundled.py")

        let originalConfig = """
        [features]
        codex_hooks = true
        unified_exec = true
        """
        try originalConfig.write(to: configToml, atomically: true, encoding: .utf8)
        try Data("new-script".utf8).write(to: bundledScript)

        try HookInstaller.installIfNeeded(
            homeDirectory: home,
            bundledScriptURL: bundledScript
        )

        let updatedConfig = try String(contentsOf: configToml, encoding: .utf8)
        XCTAssertEqual(updatedConfig, originalConfig)
    }

    func testUninstallRestoresManagedScriptWhenHooksConfigIsInvalid() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        let hooksDir = codexDir.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        let managedScript = hooksDir.appendingPathComponent("codex-island-state.py")
        let hooksConfig = codexDir.appendingPathComponent("hooks.json")

        try Data("managed-script".utf8).write(to: managedScript)
        try Data("not-json".utf8).write(to: hooksConfig)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: managedScript.path)

        XCTAssertThrowsError(try HookInstaller.uninstall(homeDirectory: home))

        XCTAssertEqual(try String(contentsOf: managedScript, encoding: .utf8), "managed-script")
        XCTAssertEqual(try String(contentsOf: hooksConfig, encoding: .utf8), "not-json")

        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: managedScript.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue, 0o755)
    }

    private func makeTemporaryHome() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
