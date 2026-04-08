import XCTest
@testable import Codex_Island

final class RemoteThreadHistoryMapperTests: XCTestCase {
    func testReasoningItemDropsEmptyThinkingText() {
        let item = RemoteAppServerThreadItem.reasoning(
            id: "reasoning-1",
            summary: [],
            content: []
        )

        XCTAssertNil(RemoteThreadHistoryMapper.chatHistoryItem(from: item))
    }

    func testPlanItemTrimsWhitespaceBeforeRenderingThinkingText() {
        let item = RemoteAppServerThreadItem.plan(
            id: "plan-1",
            text: "\n  implement the fix  \n"
        )

        let historyItem = RemoteThreadHistoryMapper.chatHistoryItem(from: item)

        guard case .thinking(let text)? = historyItem?.type else {
            return XCTFail("Expected thinking item")
        }

        XCTAssertEqual(text, "implement the fix")
    }
}
