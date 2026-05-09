//
//  LockOverlayWindow.swift
//  SAM
//
//  NSWindow-level lock overlay. Attached as a child window of each main
//  SAM window so the cover sits above the parent's content view, toolbar,
//  AND any attached sheet. SwiftUI content modifiers can't reach the
//  toolbar layer or sheet windows; an NSWindow at .floating level can.
//

import AppKit
import SwiftUI

// MARK: - LockOverlayWindow

/// Borderless, transparent NSWindow that hosts the lock UI. Created once
/// per parent window and re-attached on each lock cycle so the same
/// SwiftUI content view is reused (no rebuild cost on unlock).
final class LockOverlayWindow: NSWindow {

    /// Sentinel that lets `AppLockService` and friends filter overlays
    /// out of generic `NSApp.windows` iterations. Plain `Bool` because
    /// NSWindow can't store associated objects easily.
    let isLockOverlay: Bool = true

    init(parent: NSWindow) {
        super.init(
            contentRect: parent.contentLayoutRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // .floating sits above the parent's content + toolbar + attached
        // sheets. The Touch ID prompt itself is system-rendered above
        // everything, which is what we want.
        level = .floating
        ignoresMouseEvents = false
        // Belt-and-suspenders against legacy CGWindowList recorders.
        sharingType = .none
        // Mirror the parent's frame; the coordinator updates this when
        // the parent moves or resizes so the overlay tracks.
        setFrame(parent.frame, display: false)
        contentView = NSHostingView(rootView: LockOverlayContent())
    }

    /// Don't accept first-responder so the parent window keeps key focus
    /// when the overlay is on screen — important so menu validation
    /// (Quit/Hide) still applies to the right window context.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - LockObservingModifier

/// Attach to every SwiftUI WindowGroup/Window so its host NSWindow gets
/// registered with `LockOverlayCoordinator`. The coordinator then attaches
/// a `LockOverlayWindow` child whenever the app is locked.
///
/// Replaces the previous `.lockGuarded()` SwiftUI modifier — that one ran
/// inside the window's content view and couldn't cover sheets/toolbar.
struct LockObservingModifier: ViewModifier {

    func body(content: Content) -> some View {
        content
            .background(LockWindowAccessor())
    }
}

extension View {
    /// Register this window's host NSWindow with `LockOverlayCoordinator`
    /// so a lock overlay can be attached on lock state changes.
    func observeForLock() -> some View {
        modifier(LockObservingModifier())
    }
}

// MARK: - Window Accessor

/// Bridges from SwiftUI to the underlying NSWindow. Uses
/// `viewDidMoveToWindow` so registration fires the moment the view is
/// installed in a window hierarchy — earlier and more reliably than
/// `.onAppear` + `NSApp.windows` lookup.
private struct LockWindowAccessor: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        WindowFinderView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WindowFinderView: NSView {
        private weak var registeredWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Register the new window (if any) and unregister the prior
            // one so a view that gets re-parented (rare but possible)
            // doesn't leave a stale registration behind.
            if let prior = registeredWindow, prior !== self.window {
                LockOverlayCoordinator.shared.unregister(prior)
                registeredWindow = nil
            }
            if let new = self.window, !(new is LockOverlayWindow) {
                LockOverlayCoordinator.shared.register(new)
                registeredWindow = new
            }
        }
    }
}
