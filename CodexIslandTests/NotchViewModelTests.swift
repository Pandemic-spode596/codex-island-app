import AppKit
import XCTest
@testable import Codex_Island

@MainActor
final class NotchViewModelTests: XCTestCase {
    // notch 命中、hover 与 collapsed summary 都是强 UI 行为，优先用细粒度单测锁住几何与状态机规则。
    func testHoverLeaveClosesAfterDelayWhenOpenedByHover() async {
        let viewModel = makeViewModel(hoverCloseDelay: 0.05)
        viewModel.setHovering(true)

        viewModel.setHovering(false)
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(viewModel.status, .closed)
        XCTAssertFalse(viewModel.isHovering)
    }

    func testHoverLeaveDoesNotCloseManuallyOpenedPanel() async {
        let viewModel = makeViewModel(hoverCloseDelay: 0.05)
        viewModel.notchOpen(reason: .click)

        viewModel.setHovering(true)
        viewModel.setHovering(false)
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(viewModel.status, .opened)
        XCTAssertEqual(viewModel.openReason, .click)
    }

    func testReEnteringBeforeDelayCancelsPendingHoverClose() async {
        let viewModel = makeViewModel(hoverCloseDelay: 0.1)
        viewModel.setHovering(true)
        viewModel.setHovering(false)

        try? await Task.sleep(for: .milliseconds(40))
        viewModel.setHovering(true)
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(viewModel.status, .opened)
        XCTAssertTrue(viewModel.isHovering)
    }

    func testRemoteChatContentIdIncludesThreadId() {
        let oldThread = makeRemoteThreadState(threadId: "thread-old")
        let newThread = makeRemoteThreadState(threadId: "thread-new")

        XCTAssertNotEqual(NotchContentType.remoteChat(oldThread), NotchContentType.remoteChat(newThread))
        XCTAssertEqual(
            NotchContentType.remoteChat(newThread).id,
            "remote-chat-\(newThread.stableId)-\(newThread.threadId)"
        )
    }

    func testLocalChatContentIdIncludesSessionId() {
        let first = LocalChatTarget(logicalSessionId: "local|term|/repo", sessionId: "session-1")
        let second = LocalChatTarget(logicalSessionId: "local|term|/repo", sessionId: "session-2")

        XCTAssertNotEqual(NotchContentType.chat(first), NotchContentType.chat(second))
        XCTAssertEqual(
            NotchContentType.chat(second).id,
            "chat-\(second.logicalSessionId)-\(second.sessionId)"
        )
    }

    func testSessionPhaseSummaryCountsRunningWaitingAndIdleBuckets() {
        let summary = SessionPhaseSummary(phases: [
            .processing,
            .compacting,
            .waitingForApproval(makePermissionContext()),
            .waitingForInput,
            .idle,
            .ended
        ])

        XCTAssertEqual(summary.runningCount, 2)
        XCTAssertEqual(summary.waitingCount, 1)
        XCTAssertEqual(summary.idleCount, 2)
        XCTAssertEqual(summary.totalCount, 5)
    }

    func testSummaryBucketMappingMatchesCollapsedStateRules() {
        XCTAssertEqual(SessionPhaseHelpers.summaryBucket(for: .processing), .running)
        XCTAssertEqual(SessionPhaseHelpers.summaryBucket(for: .compacting), .running)
        XCTAssertEqual(SessionPhaseHelpers.summaryBucket(for: .waitingForInput), .idle)
        XCTAssertEqual(SessionPhaseHelpers.summaryBucket(for: .waitingForApproval(makePermissionContext())), .waiting)
        XCTAssertEqual(SessionPhaseHelpers.summaryBucket(for: .idle), .idle)
        XCTAssertNil(SessionPhaseHelpers.summaryBucket(for: .ended))
    }

    func testSummaryBucketTreatsPendingUserInputAsWaiting() {
        let pendingInteraction = PendingInteraction.userInput(
            PendingUserInputInteraction(
                id: "request-1",
                title: "Plan confirmation",
                questions: [
                    PendingInteractionQuestion(
                        id: "execute",
                        header: "Execute",
                        question: "Do you want me to execute this plan?",
                        options: [
                            PendingInteractionOption(label: "Yes", description: nil),
                            PendingInteractionOption(label: "No", description: nil)
                        ],
                        isOther: false,
                        isSecret: false
                    )
                ],
                transport: .codexLocal(callId: nil, turnId: nil)
            )
        )

        XCTAssertEqual(
            SessionPhaseHelpers.summaryBucket(for: .waitingForInput, pendingInteraction: pendingInteraction),
            .waiting
        )
        XCTAssertEqual(
            SessionPhaseHelpers.summaryBucket(for: .idle, pendingInteraction: pendingInteraction),
            .waiting
        )
    }

    func testClosedHitAreaCanExtendBeyondPhysicalNotch() {
        let geometry = NotchGeometry(
            deviceNotchRect: CGRect(x: 0, y: 0, width: 200, height: 32),
            screenRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
            windowHeight: 750
        )
        let pointInExtendedArea = CGPoint(x: 920, y: 960)

        XCTAssertFalse(geometry.isPointInClosedPanel(pointInExtendedArea))
        XCTAssertTrue(
            geometry.isPointInClosedPanel(
                pointInExtendedArea,
                visibleWidth: 332,
                horizontalOffset: 49
            )
        )
    }

    func testMouseUpDoesNotPassThroughAfterInsideClickStarts() {
        var state = NotchMousePassThroughState()

        XCTAssertFalse(state.shouldPassThrough(eventType: .leftMouseDown, hasHitTarget: true))
        XCTAssertFalse(state.shouldPassThrough(eventType: .leftMouseUp, hasHitTarget: false))
    }

    func testOutsideClickStillPassesThroughWhenNeverCaptured() {
        var state = NotchMousePassThroughState()

        XCTAssertTrue(state.shouldPassThrough(eventType: .leftMouseDown, hasHitTarget: false))
        XCTAssertTrue(state.shouldPassThrough(eventType: .leftMouseUp, hasHitTarget: false))
    }

    func testCaptureIsClearedAfterMouseUp() {
        var state = NotchMousePassThroughState()

        XCTAssertFalse(state.shouldPassThrough(eventType: .leftMouseDown, hasHitTarget: true))
        XCTAssertFalse(state.shouldPassThrough(eventType: .leftMouseUp, hasHitTarget: false))
        XCTAssertTrue(state.shouldPassThrough(eventType: .leftMouseUp, hasHitTarget: false))
    }

    private func makeViewModel(hoverCloseDelay: TimeInterval = 2.0) -> NotchViewModel {
        NotchViewModel(
            deviceNotchRect: CGRect(x: 0, y: 0, width: 200, height: 32),
            screenRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
            windowHeight: 750,
            hasPhysicalNotch: true,
            hoverCloseDelay: hoverCloseDelay,
            monitorEvents: false
        )
    }

    private func makeRemoteThreadState(threadId: String) -> RemoteThreadState {
        RemoteThreadState(
            hostId: "host-1",
            hostName: "Remote",
            threadId: threadId,
            logicalSessionId: "remote|ssh-target|/repo",
            preview: "Preview",
            name: nil,
            cwd: "/repo",
            phase: .idle,
            lastActivity: Date(),
            createdAt: Date(),
            updatedAt: Date(),
            lastMessage: nil,
            lastMessageRole: nil,
            lastToolName: nil,
            lastUserMessageDate: nil,
            history: [],
            activeTurnId: nil,
            isLoaded: true,
            canSteerTurn: false,
            pendingApproval: nil,
            pendingInteractions: [],
            connectionState: .connected,
            turnContext: .empty
        )
    }

    private func makePermissionContext() -> PermissionContext {
        PermissionContext(
            toolUseId: "tool-1",
            toolName: "shell",
            toolInput: nil,
            receivedAt: Date(timeIntervalSince1970: 1_234)
        )
    }
}
