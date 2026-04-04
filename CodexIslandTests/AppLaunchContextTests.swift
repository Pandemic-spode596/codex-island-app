import XCTest
@testable import Codex_Island

final class AppLaunchContextTests: XCTestCase {
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
