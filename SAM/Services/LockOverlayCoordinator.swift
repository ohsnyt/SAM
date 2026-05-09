//
//  LockOverlayCoordinator.swift
//  SAM
//
//  Tracks every SAM-owned NSWindow and attaches/removes a
//  `LockOverlayWindow` child window when the app's lock state changes.
//
//  Replaces the per-window SwiftUI `.lockGuarded()` modifier — that
//  approach blurred only the SwiftUI content view and could not cover
//  toolbars, title bars, or attached sheets. An NSWindow child at
//  `.floating` level covers all of those.
//

import AppKit
import Foundation
import os.log

@MainActor
final class LockOverlayCoordinator {

    static let shared = LockOverlayCoordinator()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "LockOverlayCoordinator")

    /// One entry per registered parent NSWindow. The overlay reference
    /// is `nil` while the app is unlocked and populated lazily on lock.
    /// Frame observers track the parent so the cover follows moves/resizes
    /// without exposing parent content along the trailing edge.
    private struct Registration {
        weak var window: NSWindow?
        var overlay: LockOverlayWindow?
        var resizeObserver: NSObjectProtocol?
        var moveObserver: NSObjectProtocol?
    }

    private var registrations: [Registration] = []

    private init() {}

    // MARK: - Registration

    /// Register a parent NSWindow. Idempotent: re-registering the same
    /// window is a no-op. If the app is currently locked, an overlay is
    /// attached immediately.
    func register(_ window: NSWindow) {
        guard !(window is LockOverlayWindow) else { return }
        if registrations.contains(where: { $0.window === window }) { return }
        registrations.append(Registration(window: window))

        if AppLockService.shared.isLocked {
            // Seal first regardless of visibility — orderOut'd windows
            // can still leak via backing-store capture APIs.
            window.sharingType = .none
            if window.isVisible {
                attachOverlay(toWindowAt: registrations.count - 1)
            }
        }
    }

    /// Unregister a parent NSWindow. Detaches and discards the overlay
    /// if one exists. Called when a window closes for good.
    func unregister(_ window: NSWindow) {
        for index in registrations.indices.reversed() where registrations[index].window === window {
            detachOverlay(atIndex: index)
            registrations.remove(at: index)
        }
    }

    // MARK: - Lock State

    /// Called by `AppLockService` from `lock()` and the success branch of
    /// `authenticate()`. Imperative call instead of observation so the
    /// timing is tight against the state transition.
    func handleLockStateChange(isLocked: Bool) {
        if isLocked {
            sealAllWindowsFromCapture()
            attachAllOverlays()
        } else {
            detachAllOverlays()
            restoreAllWindowSharing()
        }
    }

    // MARK: - Screen-Capture Hardening
    //
    // The lock overlay sets `sharingType = .none` on itself, which means
    // screen-capture APIs (`CGWindowListCreateImage`, ScreenCaptureKit, the
    // ⇧⌘5 screenshot tool) treat the overlay as invisible. But screen-capture
    // reads each window's backing store independently of on-screen z-order
    // — so without sealing the parent windows too, a capture tool sees right
    // through the overlay to the underlying SAM content. Setting parents to
    // `.none` while locked, and back to `.readOnly` (the macOS default) on
    // unlock, closes that hole.

    private func sealAllWindowsFromCapture() {
        for index in registrations.indices {
            registrations[index].window?.sharingType = .none
        }
    }

    private func restoreAllWindowSharing() {
        for index in registrations.indices {
            registrations[index].window?.sharingType = .readOnly
        }
    }

    // MARK: - Attach / Detach

    private func attachAllOverlays() {
        // Prune dead weak refs first.
        registrations.removeAll { $0.window == nil }
        for index in registrations.indices {
            attachOverlay(toWindowAt: index)
        }
    }

    private func detachAllOverlays() {
        for index in registrations.indices {
            detachOverlay(atIndex: index)
        }
    }

    private func attachOverlay(toWindowAt index: Int) {
        guard registrations.indices.contains(index) else { return }
        guard let parent = registrations[index].window, parent.isVisible else { return }
        guard registrations[index].overlay == nil else { return }

        let overlay = LockOverlayWindow(parent: parent)
        parent.addChildWindow(overlay, ordered: .above)
        overlay.setFrame(parent.frame, display: true)
        overlay.orderFront(nil)
        registrations[index].overlay = overlay

        // didResize covers grow/shrink; didMove covers plain drags.
        // Without both, the cover lags behind the parent on either kind
        // of motion and exposes content along the trailing edge.
        registrations[index].resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: parent,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncOverlayFrame(parentIndex: index)
            }
        }
        registrations[index].moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: parent,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncOverlayFrame(parentIndex: index)
            }
        }
    }

    private func detachOverlay(atIndex index: Int) {
        guard registrations.indices.contains(index) else { return }

        if let observer = registrations[index].resizeObserver {
            NotificationCenter.default.removeObserver(observer)
            registrations[index].resizeObserver = nil
        }
        if let observer = registrations[index].moveObserver {
            NotificationCenter.default.removeObserver(observer)
            registrations[index].moveObserver = nil
        }

        guard let overlay = registrations[index].overlay else { return }
        if let parent = registrations[index].window {
            parent.removeChildWindow(overlay)
        }
        overlay.orderOut(nil)
        registrations[index].overlay = nil
    }

    private func syncOverlayFrame(parentIndex: Int) {
        guard registrations.indices.contains(parentIndex) else { return }
        guard let parent = registrations[parentIndex].window,
              let overlay = registrations[parentIndex].overlay else { return }
        overlay.setFrame(parent.frame, display: true)
    }
}
