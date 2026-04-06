import XCTest
@testable import Codex_Island

final class AppLaunchContextTests: XCTestCase {
    // 启动期开关很小，但一旦误开自动更新就会影响测试和 Xcode 调试稳定性。
    func testAutomaticUpdateCheckIsDisabledWhileRunningTests() {
        XCTAssertFalse(
            AppLaunchContext.shouldAutomaticallyCheckForUpdates(
                isRunningTests: true,
                isDebuggerAttached: false
            )
        )
    }

    func testAutomaticUpdateCheckIsDisabledWhileDebuggerAttached() {
        XCTAssertFalse(
            AppLaunchContext.shouldAutomaticallyCheckForUpdates(
                isRunningTests: false,
                isDebuggerAttached: true
            )
        )
    }

    func testAutomaticUpdateCheckRemainsEnabledForNormalLaunches() {
        XCTAssertTrue(
            AppLaunchContext.shouldAutomaticallyCheckForUpdates(
                isRunningTests: false,
                isDebuggerAttached: false
            )
        )
    }
}
