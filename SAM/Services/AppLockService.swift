//
//  AppLockService.swift
//  SAM
//
//  App lock and biometric authentication service.
//
//  SAM always requires authentication on launch and after idle timeout.
//  Uses LocalAuthentication (Touch ID with system password fallback).
//

import AppKit
import Foundation
import LocalAuthentication
import os.log

@MainActor
@Observable
final class AppLockService {

    static let shared = AppLockService()

    nonisolated let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "AppLockService")

    // MARK: - Observable State

    var isLocked: Bool = true
    var isAuthenticating: Bool = false
    var authError: String?

    // MARK: - Settings (UserDefaults-backed)

    @ObservationIgnored private let timeoutKey = "sam.security.lockTimeoutMinutes"

    var lockTimeoutMinutes: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: timeoutKey)
            return val > 0 ? val : 5
        }
        set {
            UserDefaults.standard.set(newValue, forKey: timeoutKey)
            logger.debug("Lock timeout updated to \(newValue) minutes")
        }
    }

    // MARK: - Computed Properties

    var isBiometricAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        let available = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        if let error {
            logger.debug("Biometric not available: \(error.localizedDescription)")
        }
        return available
    }

    // MARK: - Private State

    @ObservationIgnored private var lastActiveTime: Date?
    @ObservationIgnored private var currentAuthContext: LAContext?
    @ObservationIgnored private var keyEventMonitor: Any?

    // MARK: - Initializer

    private init() {
        #if DEBUG
        // DEBUG-only test escape hatch. Set the user default once and SAM
        // launches unlocked, so the test harness can drop fixtures into
        // the inbox without anyone needing to authenticate first:
        //   defaults write sam.SAM "sam.debug.skipAppLock" -bool true
        // Production builds compile this whole branch out.
        let skip = UserDefaults.standard.bool(forKey: "sam.debug.skipAppLock")
        if skip {
            isLocked = false
            logger.notice("🔓 sam.debug.skipAppLock=true — bypassing app lock for this session (DEBUG only)")
            return
        }
        #endif
        isLocked = true
    }

    // MARK: - Authentication

    /// Authenticate using Touch ID with system password fallback. Unlocks the app on success.
    /// If an authentication dialog is already showing, cancels it and presents a fresh one
    /// so the new system dialog receives focus.
    func authenticate() {
        guard isLocked else { return }

        // Prevent duplicate auth dialogs — if one is already in flight,
        // let it complete rather than spawning a second.
        guard !isAuthenticating else { return }

        isAuthenticating = true
        authError = nil

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        currentAuthContext = context

        Task {
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "Unlock SAM to access your data"
                )
                if success {
                    isLocked = false
                    lastActiveTime = Date()
                    authError = nil
                    removeKeyEventMonitor()
                    logger.info("Authentication successful — app unlocked")
                }
            } catch {
                let laError = error as? LAError
                switch laError?.code {
                case .userCancel, .appCancel, .systemCancel:
                    logger.debug("Authentication cancelled by user or system")
                    authError = nil
                default:
                    authError = error.localizedDescription
                    logger.warning("Authentication failed: \(error.localizedDescription)")
                }
            }
            currentAuthContext = nil
            isAuthenticating = false
        }
    }

    /// Authenticate for export/import operations. Always required.
    func authenticateForExport() async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Authenticate to access SAM backup data"
            )
            if success {
                logger.debug("Export authentication successful")
            }
            return success
        } catch {
            logger.warning("Export authentication failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Lock Management

    /// Immediately lock the app: close auxiliary windows, dismiss sheets,
    /// block keyboard shortcuts, and disable menus.
    func lock() {
        isLocked = true
        closeAuxiliaryWindows()
        dismissOpenSheets()
        installKeyEventMonitor()
        logger.info("App locked")
    }

    /// Called when the app resigns active (user switches away).
    /// Records the timestamp so we can check elapsed time when the app returns.
    func appDidResignActive() {
        guard !isLocked else { return }
        lastActiveTime = Date()
    }

    /// Called when the app becomes active again.
    /// Locks if the user was away longer than the timeout.
    func appDidBecomeActive() {
        guard !isLocked else { return }

        guard let lastActive = lastActiveTime else { return }

        let elapsed = Date().timeIntervalSince(lastActive)
        let timeout = TimeInterval(lockTimeoutMinutes * 60)
        if elapsed >= timeout {
            isLocked = true
            closeAuxiliaryWindows()
            dismissOpenSheets()
            installKeyEventMonitor()
            logger.debug("App locked — inactive for \(Int(elapsed / 60)) minutes (timeout: \(self.lockTimeoutMinutes)m)")
        }
    }

    // MARK: - Launch Configuration

    /// Configure lock state on app launch. Always starts locked.
    func configureOnLaunch() {
        #if DEBUG
        // DEBUG escape hatch — same flag honored as in init().
        if UserDefaults.standard.bool(forKey: "sam.debug.skipAppLock") {
            isLocked = false
            logger.notice("🔓 sam.debug.skipAppLock=true — launching unlocked (DEBUG only)")
            return
        }
        #endif
        isLocked = true
        installKeyEventMonitor()
        logger.debug("App launch — awaiting authentication")
    }

    // MARK: - Private Helpers

    /// Known auxiliary window identifiers that must close when the app locks.
    /// The main WindowGroup has no explicit id, so it is excluded by omission.
    private static let auxiliaryWindowIDs: Set<String> = [
        "prompt-lab", "guide", "quick-note", "clipboard-capture", "compose-message"
    ]

    /// Close all auxiliary windows so they can't be read while locked.
    /// Matches SwiftUI Settings (by Apple's internal identifier prefix) and
    /// SAM's named windows (Prompt Lab, Guide, Quick Note, Compose, Clipboard).
    private func closeAuxiliaryWindows() {
        for window in NSApplication.shared.windows where window.isVisible {
            let id = window.identifier?.rawValue ?? ""
            let isSettings = id.contains("Settings")
            let isAuxiliary = Self.auxiliaryWindowIDs.contains(where: { id.contains($0) })

            if isSettings || isAuxiliary {
                window.close()
                logger.debug("Closed auxiliary window on lock: \(id)")
            }
        }
    }

    /// Dismiss any open sheets so they can't be read behind the lock overlay.
    private func dismissOpenSheets() {
        for window in NSApplication.shared.windows where window.isVisible {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet, returnCode: .cancel)
                logger.debug("Dismissed sheet on lock")
            }
        }
    }

    // MARK: - Keyboard Event Blocking

    /// Install a local event monitor that consumes all keyboard events while locked.
    /// Only ⌘Q (quit) and ⌘H (hide) are allowed through.
    private func installKeyEventMonitor() {
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.isLocked else { return event }

            // Allow ⌘Q (quit) and ⌘H (hide) — standard macOS behavior
            if event.modifierFlags.contains(.command) {
                let key = event.charactersIgnoringModifiers?.lowercased()
                if key == "q" || key == "h" { return event }
            }

            // Consume all other key events
            return nil
        }
        logger.debug("Key event monitor installed")
    }

    /// Remove the keyboard event monitor after unlock.
    private func removeKeyEventMonitor() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
            logger.debug("Key event monitor removed")
        }
    }

    // MARK: - Menu Validation

    /// Called by the app delegate's `validateMenuItem` to control menu state.
    /// Returns `true` only for Quit, Hide, and minimize when locked.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard isLocked else { return true }

        // Always allow these system actions
        let allowedSelectors: Set<Selector> = [
            #selector(NSApplication.terminate(_:)),
            #selector(NSApplication.hide(_:)),
            #selector(NSApplication.hideOtherApplications(_:)),
            #selector(NSApplication.unhideAllApplications(_:)),
            #selector(NSWindow.miniaturize(_:)),
            #selector(NSWindow.performClose(_:)),
        ]

        if let action = menuItem.action, allowedSelectors.contains(action) {
            return true
        }

        return false
    }
}
