//
//  GlobalHotkeyService.swift
//  SAM
//
//  Global Clipboard Capture Hotkey
//
//  Manages global ⌃⇧V hotkey registration via NSEvent global monitor
//  and Accessibility permission checking via AXIsProcessTrusted.
//

import AppKit
import ApplicationServices
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "GlobalHotkeyService")

@MainActor @Observable
final class GlobalHotkeyService {

    static let shared = GlobalHotkeyService()

    // MARK: - State

    private(set) var isRegistered = false
    private(set) var accessibilityGranted = false
    private var globalMonitor: Any?

    // MARK: - UserDefaults Key

    static let enabledKey = "sam.clipboardCapture.enabled"

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    // MARK: - Init

    private init() {
        accessibilityGranted = checkAccessibilityPermission()
    }

    // MARK: - Accessibility

    /// Returns true if the app has Accessibility permission.
    @discardableResult
    func checkAccessibilityPermission() -> Bool {
        let granted = AXIsProcessTrusted()
        accessibilityGranted = granted
        return granted
    }

    /// Ensures the app appears in the Accessibility list, then opens System Settings.
    /// `AXIsProcessTrustedWithOptions(prompt: true)` adds the app to the list the first
    /// time it's called. Subsequent calls are no-ops (no dialog shown). So we always
    /// follow up by opening the Accessibility pane directly — the user just flips the toggle.
    func promptForAccessibility() {
        // Ensure app is in the Accessibility list (no-op if already there)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        // Open System Settings → Privacy & Security → Accessibility
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }

        // Poll a few times — the user may grant permission shortly after
        Task {
            for delay in [1, 3, 5, 10] {
                try? await Task.sleep(for: .seconds(delay))
                if checkAccessibilityPermission() {
                    if isEnabled { registerHotkey() }
                    logger.info("Accessibility permission granted after prompt")
                    return
                }
            }
        }
    }

    // MARK: - Hotkey Registration

    func registerHotkey() {
        guard globalMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            // ⌃⇧V: control + shift + keyCode 9 (V key)
            guard event.modifierFlags.contains([.control, .shift]),
                  event.keyCode == 9 else { return }

            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .samOpenClipboardCapture, object: nil)
                logger.debug("Global hotkey ⌃⇧V triggered — opening clipboard capture")
            }
        }

        isRegistered = globalMonitor != nil
        if isRegistered {
            logger.debug("Global hotkey ⌃⇧V registered")
        } else {
            logger.warning("Failed to register global hotkey")
        }
    }

    func unregisterHotkey() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
            isRegistered = false
            logger.debug("Global hotkey ⌃⇧V unregistered")
        }
    }
}
