//
//  NotchView.swift
//  CodexIsland
//
//  The main dynamic island SwiftUI view with accurate notch shape
//

import AppKit
import CoreGraphics
import SwiftUI

// Corner radius constants
private let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

struct NotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @StateObject private var sessionMonitor = CodexSessionMonitor()
    @StateObject private var remoteSessionMonitor = RemoteSessionMonitor.shared
    @StateObject private var activityCoordinator = NotchActivityCoordinator.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var previousPendingIds: Set<String> = []
    @State private var previousWaitingForInputIds: Set<String> = []
    @State private var isVisible: Bool = false
    @State private var isHovering: Bool = false
    @State private var isBouncing: Bool = false

    @Namespace private var activityNamespace

    private var collapsedSummary: SessionPhaseSummary {
        SessionPhaseSummary(
            localSessions: sessionMonitor.instances,
            remoteThreads: remoteSessionMonitor.threads
        )
    }

    private var hasVisibleSessions: Bool {
        collapsedSummary.totalCount > 0
    }

    /// Whether any session is currently processing or compacting
    private var isAnyProcessing: Bool {
        collapsedSummary.runningCount > 0
    }

    /// Whether any session has a pending permission request
    private var hasPendingPermission: Bool {
        sessionMonitor.instances.contains { $0.primaryPendingInteraction?.isApproval == true } ||
        remoteSessionMonitor.threads.contains { $0.primaryPendingInteraction?.isApproval == true }
    }

    private var allPhases: [SessionPhase] {
        sessionMonitor.instances.map(\.phase) + remoteSessionMonitor.threads.map(\.phase)
    }

    // MARK: - Sizing

    private var closedNotchSize: CGSize {
        CGSize(
            width: viewModel.deviceNotchRect.width,
            height: viewModel.deviceNotchRect.height
        )
    }

    private var notchSize: CGSize {
        switch viewModel.status {
        case .closed, .popping:
            return closedNotchSize
        case .opened:
            return viewModel.openedSize
        }
    }

    private var collapsedSummaryExtensionWidth: CGFloat {
        guard showsCollapsedSummary else { return 0 }
        return ClosedStatusSummaryView.preferredWidth + 18
    }

    private var collapsedLeadingVisibleWidth: CGFloat {
        guard showsCollapsedSummary else { return 0 }
        return 28
    }

    private var collapsedHeaderWidth: CGFloat {
        closedNotchSize.width + collapsedLeadingVisibleWidth + collapsedSummaryExtensionWidth
    }

    private var collapsedHeaderOffset: CGFloat {
        guard showsCollapsedSummary else { return 0 }
        return (collapsedSummaryExtensionWidth - collapsedLeadingVisibleWidth) / 2
    }

    private var closedHitAreaWidth: CGFloat {
        if showsCollapsedSummary {
            return collapsedHeaderWidth + cornerRadiusInsets.closed.bottom * 2
        }
        return closedNotchSize.width
    }

    private var closedHitAreaOffset: CGFloat {
        showsCollapsedSummary ? collapsedHeaderOffset : 0
    }

    // MARK: - Corner Radii

    private var topCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.bottom
            : cornerRadiusInsets.closed.bottom
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }

    // Animation springs
    private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                notchContainer
            }
        }
        .opacity(isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onAppear {
            sessionMonitor.startMonitoring()
            remoteSessionMonitor.startMonitoring()
            syncClosedHitArea()
            // On non-notched devices, keep visible so users have a target to interact with
            if !viewModel.hasPhysicalNotch {
                isVisible = true
            }
        }
        .onChange(of: viewModel.status) { oldStatus, newStatus in
            syncClosedHitArea()
            handleStatusChange(from: oldStatus, to: newStatus)
        }
        .onChange(of: sessionMonitor.pendingInstances) { _, sessions in
            handlePendingSessionsChange(sessions)
        }
        .onChange(of: sessionMonitor.instances) { _, instances in
            syncClosedHitArea()
            handleProcessingChange()
            handleWaitingForInputChange(instances)
        }
        .onChange(of: remoteSessionMonitor.threads) { _, threads in
            syncClosedHitArea()
            handleProcessingChange()
            handleRemotePendingChange(threads)
            handleRemoteWaitingForInputChange(threads)
        }
    }

    @ViewBuilder
    private var notchContainer: some View {
        let isOpened = viewModel.status == .opened
        let panelWidth = isOpened ? nil : collapsedHeaderWidth
        let maxPanelWidth = isOpened ? notchSize.width : nil
        let panelHorizontalPadding = isOpened ? cornerRadiusInsets.opened.top : cornerRadiusInsets.closed.bottom
        let panelBottomPadding: CGFloat = isOpened ? 12 : 0
        let panelShadowColor = (isOpened || isHovering) ? Color.black.opacity(0.7) : .clear
        let panelMaxHeight = isOpened ? notchSize.height : nil
        let panelOffsetX = isOpened ? 0 : collapsedHeaderOffset

        notchLayout
            .frame(width: panelWidth, alignment: .top)
            .frame(maxWidth: maxPanelWidth, alignment: .top)
            .padding(.horizontal, panelHorizontalPadding)
            .padding([.horizontal, .bottom], panelBottomPadding)
            .background(.black)
            .clipShape(currentNotchShape)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.black)
                    .frame(height: 1)
                    .padding(.horizontal, topCornerRadius)
            }
            .shadow(color: panelShadowColor, radius: 6)
            .frame(width: panelWidth, alignment: .top)
            .frame(maxWidth: maxPanelWidth, maxHeight: panelMaxHeight, alignment: .top)
            .animation(isOpened ? openAnimation : closeAnimation, value: viewModel.status)
            .animation(openAnimation, value: notchSize)
            .animation(.smooth, value: activityCoordinator.expandingActivity)
            .animation(.smooth, value: collapsedSummary)
            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isBouncing)
            .offset(x: panelOffsetX)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                    isHovering = hovering
                }
            }
            .onTapGesture {
                if viewModel.status != .opened {
                    viewModel.notchOpen(reason: .click)
                }
            }
    }

    // MARK: - Notch Layout

    private var isProcessing: Bool {
        collapsedSummary.runningCount > 0
    }

    /// Whether to show the collapsed summary while the island is closed.
    private var showsCollapsedSummary: Bool {
        viewModel.status != .opened && hasVisibleSessions
    }

    @ViewBuilder
    private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row - always present, contains crab and spinner that persist across states
            headerRow
                .frame(height: max(24, closedNotchSize.height))

            // Main content only when opened
            if viewModel.status == .opened {
                contentView
                    .frame(width: notchSize.width - 24) // Fixed width to prevent reflow
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.smooth(duration: 0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.15))
                        )
                    )
            }
        }
    }

    // MARK: - Header Row (persists across states)

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 0) {
            if viewModel.status == .opened {
                openedHeaderContent
            } else if showsCollapsedSummary {
                HStack(spacing: 0) {
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(.clear)
                            .frame(
                                width: collapsedLeadingVisibleWidth + closedNotchSize.width - cornerRadiusInsets.closed.top + (isBouncing ? 16 : 0)
                            )

                        CodexCrabIcon(size: 14, animateLegs: isProcessing)
                            .matchedGeometryEffect(id: "crab", in: activityNamespace, isSource: showsCollapsedSummary)
                            .padding(.leading, 8)
                    }

                    ClosedStatusSummaryView(summary: collapsedSummary)
                        .frame(width: collapsedSummaryExtensionWidth, alignment: .leading)
                }
            } else {
                Rectangle()
                    .fill(.clear)
                    .frame(width: closedNotchSize.width - 20)
            }
        }
        .frame(height: closedNotchSize.height)
    }

    // MARK: - Opened Header Content

    @ViewBuilder
    private var openedHeaderContent: some View {
        HStack(spacing: 12) {
            if !showsCollapsedSummary {
                CodexCrabIcon(size: 14)
                    .matchedGeometryEffect(id: "crab", in: activityNamespace, isSource: !showsCollapsedSummary)
                    .padding(.leading, 8)
            }

            Spacer()

            // Menu toggle
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    viewModel.toggleMenu()
                    if viewModel.contentType == .menu {
                        updateManager.markUpdateSeen()
                    }
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: viewModel.contentType == .menu ? "xmark" : "line.3.horizontal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())

                    // Green dot for unseen update
                    if updateManager.hasUnseenUpdate && viewModel.contentType != .menu {
                        Circle()
                            .fill(TerminalColors.green)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: 2)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Content View (Opened State)

    @ViewBuilder
    private var contentView: some View {
        Group {
            switch viewModel.contentType {
            case .instances:
                CodexInstancesView(
                    sessionMonitor: sessionMonitor,
                    remoteSessionMonitor: remoteSessionMonitor,
                    viewModel: viewModel
                )
            case .menu:
                NotchMenuView(viewModel: viewModel)
            case .remoteHosts:
                RemoteHostsView(viewModel: viewModel)
            case .chat(let target):
                if let session = sessionMonitor.instances.first(where: { $0.sessionId == target.sessionId }) ??
                    sessionMonitor.instances.first(where: { $0.logicalSessionId == target.logicalSessionId }) {
                    ChatView(
                        logicalSessionId: target.logicalSessionId,
                        preferredSessionId: target.sessionId,
                        initialSession: session,
                        sessionMonitor: sessionMonitor,
                        viewModel: viewModel
                    )
                    .id("local-chat-\(target.logicalSessionId)-\(target.sessionId)")
                } else {
                    CodexInstancesView(
                        sessionMonitor: sessionMonitor,
                        remoteSessionMonitor: remoteSessionMonitor,
                        viewModel: viewModel
                    )
                    .onAppear {
                        viewModel.exitChat()
                    }
                }
            case .remoteChat(let thread):
                RemoteChatView(
                    initialThread: thread,
                    remoteSessionMonitor: remoteSessionMonitor,
                    viewModel: viewModel
                )
                .id("remote-chat-\(thread.stableId)-\(thread.threadId)")
            }
        }
        .frame(width: notchSize.width - 24) // Fixed width to prevent text reflow
        // Removed .id() - was causing view recreation and performance issues
    }

    // MARK: - Event Handlers

    private func handleProcessingChange() {
        if isAnyProcessing || hasPendingPermission {
            activityCoordinator.showActivity(type: .codex)
        } else {
            activityCoordinator.hideActivity()
        }

        if hasVisibleSessions {
            isVisible = true
            return
        }

        if viewModel.status == .closed && viewModel.hasPhysicalNotch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if !hasVisibleSessions && viewModel.status == .closed {
                    isVisible = false
                }
            }
        }
    }

    private func handleStatusChange(from _: NotchStatus, to newStatus: NotchStatus) {
        switch newStatus {
        case .opened, .popping:
            isVisible = true
        case .closed:
            guard viewModel.hasPhysicalNotch else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if viewModel.status == .closed && !hasVisibleSessions && !activityCoordinator.expandingActivity.show {
                    isVisible = false
                }
            }
        }
    }

    private func syncClosedHitArea() {
        viewModel.updateClosedHitArea(
            width: closedHitAreaWidth,
            horizontalOffset: closedHitAreaOffset
        )
    }

    private func handlePendingSessionsChange(_ sessions: [SessionState]) {
        let currentIds = Set(sessions.map { $0.stableId })
        let combinedIds = currentIds.union(remoteSessionMonitor.threads.filter(\.needsAttention).map(\.stableId))
        let newPendingIds = currentIds.subtracting(previousPendingIds)

        if !newPendingIds.isEmpty &&
           viewModel.status == .closed &&
           !TerminalVisibilityDetector.isTerminalVisibleOnCurrentSpace() {
            viewModel.notchOpen(reason: .notification)
        }

        previousPendingIds = combinedIds
    }

    private func handleRemotePendingChange(_ threads: [RemoteThreadState]) {
        let currentIds = Set(threads.filter(\.needsAttention).map(\.stableId))
        let combinedIds = currentIds.union(sessionMonitor.pendingInstances.map(\.stableId))
        let newPendingIds = currentIds.subtracting(previousPendingIds)

        if !newPendingIds.isEmpty &&
           viewModel.status == .closed &&
           !TerminalVisibilityDetector.isTerminalVisibleOnCurrentSpace() {
            viewModel.notchOpen(reason: .notification)
        }

        previousPendingIds = combinedIds
    }

    private func handleWaitingForInputChange(_ instances: [SessionState]) {
        let waitingForInputSessions = instances.filter { $0.phase == .waitingForInput }
        let currentIds = Set(waitingForInputSessions.map { $0.stableId })
        let newWaitingIds = currentIds.subtracting(previousWaitingForInputIds)

        if !newWaitingIds.isEmpty {
            if viewModel.status == .closed {
                viewModel.notchOpen(reason: .notification)
            }

            let newlyWaitingSessions = waitingForInputSessions.filter { newWaitingIds.contains($0.stableId) }

            if let soundName = AppSettings.notificationSound.soundName {
                Task {
                    let shouldPlaySound = await shouldPlayNotificationSound(for: newlyWaitingSessions)
                    if shouldPlaySound {
                        _ = await MainActor.run {
                            NSSound(named: soundName)?.play()
                        }
                    }
                }
            }

            DispatchQueue.main.async {
                isBouncing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isBouncing = false
                }
            }
        }

        previousWaitingForInputIds = currentIds.union(
            remoteSessionMonitor.threads
                .filter { $0.phase == .waitingForInput }
                .map(\.stableId)
        )
    }

    private func handleRemoteWaitingForInputChange(_ threads: [RemoteThreadState]) {
        let waitingForInputThreads = threads.filter { $0.phase == .waitingForInput }
        let currentIds = Set(waitingForInputThreads.map(\.stableId))
        let newWaitingIds = currentIds.subtracting(previousWaitingForInputIds)

        if !newWaitingIds.isEmpty {
            if viewModel.status == .closed {
                viewModel.notchOpen(reason: .notification)
            }

            DispatchQueue.main.async {
                isBouncing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isBouncing = false
                }
            }
        }

        previousWaitingForInputIds = currentIds.union(
            sessionMonitor.instances
                .filter { $0.phase == .waitingForInput }
                .map(\.stableId)
        )
    }

    /// Determine if notification sound should play for the given sessions
    /// Returns true if ANY session is not actively focused
    private func shouldPlayNotificationSound(for sessions: [SessionState]) async -> Bool {
        for session in sessions {
            guard let pid = session.pid else {
                // No PID means we can't check focus, assume not focused
                return true
            }

            let isFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPid: pid)
            if !isFocused {
                return true
            }
        }

        return false
    }
}
