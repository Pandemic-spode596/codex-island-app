//
//  TerminalFocusCoordinator.swift
//  CodexIsland
//
//  Unified entry point for focusing a session's terminal target.
//

import AppKit
import Foundation

actor TerminalFocusCoordinator {
    static let shared = TerminalFocusCoordinator()

    private init() {}

    func focus(session: SessionState) async -> Bool {
        if await canFocusWithNativeScript(session: session) {
            return true
        }

        guard let target = await preferredTarget(for: session) else {
            return await focusFallback(session: session)
        }

        switch target.kind {
        case .tmuxPane:
            return await focusTmuxTarget(session: session, target: target)
        case .nativeWindow:
            return await focusNativeTarget(session: session, target: target)
        }
    }

    private func canFocusWithNativeScript(session: SessionState) async -> Bool {
        guard !session.isInTmux else { return false }
        return await NativeTerminalScriptFocuser.shared.focus(session: session)
    }

    private func preferredTarget(for session: SessionState) async -> TerminalFocusTarget? {
        if let target = session.focusTarget, session.focusCapability == .ready {
            return target
        }

        let resolution = await TerminalWindowResolver.shared.resolve(for: session)
        if resolution.focusCapability == .ready {
            return resolution.focusTarget
        }

        return session.focusTarget ?? resolution.focusTarget
    }

    private func focusNativeTarget(session: SessionState, target: TerminalFocusTarget) async -> Bool {
        if await NativeTerminalWindowResolver.shared.focus(target: target) == .ready {
            return true
        }

        guard let refreshedTarget = await refreshedNativeTarget(for: session) else {
            return await focusFallback(session: session)
        }

        if await NativeTerminalWindowResolver.shared.focus(target: refreshedTarget) == .ready {
            return true
        }

        return await focusFallback(session: session)
    }

    private func refreshedNativeTarget(for session: SessionState) async -> TerminalFocusTarget? {
        let resolution = await TerminalWindowResolver.shared.resolve(for: session)
        guard resolution.focusCapability == .ready,
              let target = resolution.focusTarget,
              target.kind == .nativeWindow else {
            return nil
        }
        return target
    }

    private func focusTmuxTarget(session: SessionState, target: TerminalFocusTarget) async -> Bool {
        guard let targetString = target.tmuxTarget,
              let tmuxTarget = TmuxTarget(from: targetString) else {
            return await focusFallback(session: session)
        }

        _ = await TmuxController.shared.switchToPane(target: tmuxTarget)

        if await NativeTerminalWindowResolver.shared.focus(target: target) == .ready {
            return true
        }

        if let pid = session.pid {
            return await YabaiController.shared.focusWindow(forClaudePid: pid)
        }

        return await focusFallback(session: session)
    }

    private func focusFallback(session: SessionState) async -> Bool {
        if session.isInTmux {
            if let pid = session.pid, await YabaiController.shared.focusWindow(forClaudePid: pid) {
                return true
            }

            if await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd) {
                return true
            }
        }

        if let appPid = session.terminalProcessId,
           let app = NSRunningApplication(processIdentifier: pid_t(appPid)) {
            return app.activate(options: [.activateAllWindows])
        }

        if let app = TerminalAppRegistry.runningApplication(
            bundleId: session.terminalBundleId,
            hint: session.terminalName
        ) {
            return app.activate(options: [.activateAllWindows])
        }

        if let pid = session.pid {
            return await YabaiController.shared.focusWindow(forClaudePid: pid)
        }

        return false
    }
}
