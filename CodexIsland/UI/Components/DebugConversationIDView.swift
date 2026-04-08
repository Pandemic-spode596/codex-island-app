//
//  DebugConversationIDView.swift
//  CodexIsland
//
//  Debug-only conversation/session identifier row with clipboard copy.
//

import AppKit
import SwiftUI

struct DebugConversationIDView: View {
    let label: String
    let value: String

    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.45))

            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.78))
                .lineLimit(1)
                .textSelection(.enabled)

            Button(action: copyValue) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(didCopy ? 0.9 : 0.58))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(didCopy ? "Copied" : "Copy \(label)")
        }
    }

    private func copyValue() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)

        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            didCopy = false
        }
    }
}
