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

    func testUserMessageSplitsImageIntoDedicatedHistoryItemAndStripsPlaceholderText() {
        let item = RemoteAppServerThreadItem.userMessage(
            id: "user-1",
            content: [
                .text("<image name=[Image #1]></image>\n这里的 [Image #1] 应该显示成图片。"),
                .localImage("/tmp/debug.png")
            ]
        )

        let historyItems = RemoteThreadHistoryMapper.chatHistoryItems(from: item)

        XCTAssertEqual(historyItems.count, 2)
        guard case .user(let text) = historyItems[0].type else {
            return XCTFail("Expected first history item to be user text")
        }
        XCTAssertEqual(text, "这里的应该显示成图片。")

        guard case .userImage(let attachment) = historyItems[1].type else {
            return XCTFail("Expected second history item to be user image")
        }
        XCTAssertEqual(attachment.source, .localPath("/tmp/debug.png"))
    }
}
