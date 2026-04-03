//
//  NotchGeometry.swift
//  CodexIsland
//
//  Geometry calculations for the notch
//

import CoreGraphics
import Foundation

/// Pure geometry calculations for the notch
struct NotchGeometry: Sendable {
    let deviceNotchRect: CGRect
    let screenRect: CGRect
    let windowHeight: CGFloat

    private let closedHorizontalPadding: CGFloat = 10
    private let closedVerticalPadding: CGFloat = 5

    /// The notch rect in screen coordinates (for hit testing with global mouse position)
    var notchScreenRect: CGRect {
        CGRect(
            x: screenRect.midX - deviceNotchRect.width / 2,
            y: screenRect.maxY - deviceNotchRect.height,
            width: deviceNotchRect.width,
            height: deviceNotchRect.height
        )
    }

    /// The closed panel rect in screen coordinates for the currently visible width.
    func closedScreenRect(
        visibleWidth: CGFloat? = nil,
        horizontalOffset: CGFloat = 0
    ) -> CGRect {
        let width = max(deviceNotchRect.width, visibleWidth ?? deviceNotchRect.width)
        return CGRect(
            x: screenRect.midX - width / 2 + horizontalOffset,
            y: screenRect.maxY - deviceNotchRect.height,
            width: width,
            height: deviceNotchRect.height
        )
    }

    /// The closed interactive rect in window coordinates, including hover/click padding.
    func closedInteractiveWindowRect(
        visibleWidth: CGFloat? = nil,
        horizontalOffset: CGFloat = 0
    ) -> CGRect {
        let screenRect = closedInteractiveScreenRect(
            visibleWidth: visibleWidth,
            horizontalOffset: horizontalOffset
        )
        return CGRect(
            x: screenRect.minX - self.screenRect.minX,
            y: screenRect.minY - (self.screenRect.maxY - windowHeight),
            width: screenRect.width,
            height: screenRect.height
        )
    }

    /// The opened panel rect in screen coordinates for a given size
    func openedScreenRect(for size: CGSize) -> CGRect {
        // Match the rendered opened panel more conservatively so the
        // SwiftUI surface and AppKit/global hit-testing agree on the
        // interactive region, especially for bottom menu rows.
        let width = size.width + 62
        let height = size.height + 36
        return CGRect(
            x: screenRect.midX - width / 2,
            y: screenRect.maxY - height,
            width: width,
            height: height
        )
    }

    private func closedInteractiveScreenRect(
        visibleWidth: CGFloat? = nil,
        horizontalOffset: CGFloat = 0
    ) -> CGRect {
        closedScreenRect(
            visibleWidth: visibleWidth,
            horizontalOffset: horizontalOffset
        )
        .insetBy(dx: -closedHorizontalPadding, dy: -closedVerticalPadding)
    }

    /// Check if a point is in the notch area (with padding for easier interaction)
    func isPointInClosedPanel(
        _ point: CGPoint,
        visibleWidth: CGFloat? = nil,
        horizontalOffset: CGFloat = 0
    ) -> Bool {
        closedInteractiveScreenRect(
            visibleWidth: visibleWidth,
            horizontalOffset: horizontalOffset
        )
        .contains(point)
    }

    /// Check if a point is in the opened panel area
    func isPointInOpenedPanel(_ point: CGPoint, size: CGSize) -> Bool {
        openedScreenRect(for: size).contains(point)
    }

    /// Check if a point is outside the opened panel (for closing)
    func isPointOutsidePanel(_ point: CGPoint, size: CGSize) -> Bool {
        !openedScreenRect(for: size).contains(point)
    }
}
