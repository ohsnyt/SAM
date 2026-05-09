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
        }
    }

    // MARK: - Computed Properties

    var isBiometricAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        let available = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        _ = error
        return available
    }

    // MARK: - Private State

    @ObservationIgnored private var lastActiveTime: Date?
    @ObservationIgnored private var currentAuthContext: LAContext?
    @ObservationIgnored private var keyEventMonitor: Any?
    @ObservationIgnored private var screenLockObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var windowKeyObserver: NSObjectProtocol?
    @ObservationIgnored private var didRetryAfterSystemCancel = false

    /// Last user input within the app (mouse move, click, scroll, key).
    /// Drives the foreground inactivity timer — without this, the app
    /// only locks on resign-active or screen events, never while the
    /// user is sitting on SAM doing nothing.
    @ObservationIgnored private var lastActivityAt: Date = Date()
    @ObservationIgnored private var activityMonitor: Any?
    @ObservationIgnored private var idleTimer: Timer?

    /// Snapshot of windows that were visible when lock fired. Used to
    /// `orderFront(nil)` only those on unlock, preserving z-order intent
    /// instead of bringing every NSWindow the app has ever spawned to the
    /// foreground.
    @ObservationIgnored private var hiddenWindowsAtLock: [NSWindow] = []

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
    ///
    /// Always creates a fresh `LAContext` per call — reusing a context across
    /// attempts can leave it in a "canceled" state where subsequent
    /// `evaluatePolicy` returns immediately without prompting.
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
        let startedAt = Date()

        Task {
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "Unlock SAM to access your data"
                )
                if success {
                    isLocked = false
                    lastActiveTime = Date()
                    lastActivityAt = Date()
                    authError = nil
                    didRetryAfterSystemCancel = false
                    removeKeyEventMonitor()
                    LockOverlayCoordinator.shared.handleLockStateChange(isLocked: false)
                    restoreVisibleWindows()
                    ModalCoordinator.shared.handleLockStateChange(isLocked: false)
                }
            } catch {
                let laError = error as? LAError
                let elapsed = Date().timeIntervalSince(startedAt)
                switch laError?.code {
                case .userCancel, .appCancel, .systemCancel:
                    authError = nil
                    // Documented LAContext quirk (plan §8): evaluatePolicy can
                    // return *.systemCancel/.appCancel within a few ms when the
                    // system isn't ready to host the prompt (e.g., screen still
                    // unlocking, app not yet frontmost). One silent retry
                    // recovers; loops are guarded by didRetryAfterSystemCancel.
                    if elapsed < 0.5, !didRetryAfterSystemCancel {
                        didRetryAfterSystemCancel = true
                        currentAuthContext = nil
                        isAuthenticating = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                            guard let self, self.isLocked, !self.isAuthenticating else { return }
                            self.authenticate()
                        }
                        return
                    }
                default:
                    authError = error.localizedDescription
                    logger.warning("Authentication failed: \(error.localizedDescription)")
                }
            }
            currentAuthContext = nil
            isAuthenticating = false
        }
    }

    /// Auto-prompt biometrics when the app is locked and frontmost.
    /// Safe to call repeatedly — guards against re-entry and inactive state.
    func tryAutoAuthenticate() {
        guard isLocked, !isAuthenticating else { return }
        guard NSApp.isActive else { return }
        authenticate()
    }

    /// Variant for screen-unlock / wake / screensaver-stop paths. The system
    /// is mid-transition; `NSApp.isActive` may briefly be false before the OS
    /// hands focus back. Skip the active check — the LAContext fast-cancel
    /// retry inside `authenticate()` handles the case where the system isn't
    /// quite ready yet.
    func tryAutoAuthenticateAfterSystemEvent(source: String) {
        _ = source
        guard isLocked, !isAuthenticating else { return }
        didRetryAfterSystemCancel = false
        authenticate()
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
            return success
        } catch {
            logger.warning("Export authentication failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Lock Management

    /// Immediately lock the app: hide auxiliary windows (preserving their
    /// SwiftUI state for instant restore), attach lock overlays to every
    /// remaining visible main window, dismiss sheets, block keyboard
    /// shortcuts, and disable menus. Auto-prompts biometrics on the next
    /// activation tick.
    func lock() {
        isLocked = true
        hideAuxiliaryWindows()
        // Overlay attach must run AFTER hideAuxiliaryWindows so we don't
        // build covers for windows we're about to orderOut. The coordinator
        // skips windows that aren't visible.
        LockOverlayCoordinator.shared.handleLockStateChange(isLocked: true)
        // Dismiss alerts/sheets/popovers/file panels via the coordinator.
        // SwiftUI presentation state lives in @State on the host view —
        // each registration flips its own binding, which is the only clean
        // way to tear down a modal without leaving SwiftUI state stale.
        ModalCoordinator.shared.handleLockStateChange(isLocked: true)
        installKeyEventMonitor()
        // Queue auto-prompt — fires the moment SAM is frontmost. If SAM
        // lost focus during the lock event (e.g., screensaver took over)
        // the guard inside tryAutoAuthenticate exits early; the prompt
        // appears later from didBecomeActive instead.
        tryAutoAuthenticate()
    }

    /// Called when the app resigns active (user switches away).
    /// Records the timestamp so we can check elapsed time when the app returns.
    func appDidResignActive() {
        guard !isLocked else { return }
        lastActiveTime = Date()
    }

    /// Called when the app becomes active again.
    /// Locks if the user was away longer than the timeout, then auto-prompts Touch ID if locked.
    func appDidBecomeActive() {
        if !isLocked, let lastActive = lastActiveTime {
            let elapsed = Date().timeIntervalSince(lastActive)
            let timeout = TimeInterval(lockTimeoutMinutes * 60)
            if elapsed >= timeout {
                lock()
                return
            }
        }

        tryAutoAuthenticate()
    }

    // MARK: - Launch Configuration

    /// Configure lock state on app launch. Always starts locked.
    func configureOnLaunch() {
        #if DEBUG
        // DEBUG escape hatch — same flag honored as in init().
        if UserDefaults.standard.bool(forKey: "sam.debug.skipAppLock") {
            isLocked = false
            logger.notice("🔓 sam.debug.skipAppLock=true — launching unlocked (DEBUG only)")
            installScreenLockObservers()
            installActivityTracking()
            return
        }
        #endif
        isLocked = true
        installKeyEventMonitor()
        installScreenLockObservers()
        installActivityTracking()
    }

    // MARK: - Foreground Inactivity Timer

    /// Track in-app user activity and lock when idle exceeds the timeout.
    /// Without this, sitting on SAM without interacting never locks —
    /// resign-active is the only path that records inactivity, but the
    /// user never resigns active when they're staring at the app.
    private func installActivityTracking() {
        if activityMonitor == nil {
            let mask: NSEvent.EventTypeMask = [
                .keyDown, .leftMouseDown, .rightMouseDown,
                .otherMouseDown, .scrollWheel, .mouseMoved
            ]
            activityMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.lastActivityAt = Date()
                }
                return event
            }
        }

        idleTimer?.invalidate()
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkIdleTimeout() }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
        lastActivityAt = Date()
    }

    private func checkIdleTimeout() {
        guard !isLocked else { return }
        let elapsed = Date().timeIntervalSince(lastActivityAt)
        let timeout = TimeInterval(lockTimeoutMinutes * 60)
        guard elapsed >= timeout else { return }
        lock()
    }

    /// Subscribe to the system events that mean "someone might walk away
    /// with the screen visible" — screen lock, screensaver start, and
    /// display sleep. Any of these should engage SAM's lock so the user
    /// has to re-authenticate on return.
    ///
    /// We don't also observe unlock: on unlock the user is already looking
    /// at the lock overlay, and they tap or Touch ID to proceed. Auto-
    /// unlocking on screen unlock would defeat the whole point.
    private func installScreenLockObservers() {
        guard screenLockObservers.isEmpty else { return }

        let dc = DistributedNotificationCenter.default()
        let ws = NSWorkspace.shared.notificationCenter

        screenLockObservers.append(dc.addObserver(
            forName: .init("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreenEvent(source: "screenIsLocked") }
        })

        screenLockObservers.append(dc.addObserver(
            forName: .init("com.apple.screensaver.didstart"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreenEvent(source: "screensaver.didstart") }
        })

        screenLockObservers.append(ws.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreenEvent(source: "workspace.willSleep") }
        })

        // Unlock-side observers: re-prompt biometrics when the system returns
        // from screen lock / screensaver / sleep. Without these the user has
        // to click the overlay because the original `tryAutoAuthenticate()`
        // fired while the OS lock screen was on top and got swallowed.
        screenLockObservers.append(dc.addObserver(
            forName: .init("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tryAutoAuthenticateAfterSystemEvent(source: "screenIsUnlocked")
            }
        })

        screenLockObservers.append(dc.addObserver(
            forName: .init("com.apple.screensaver.didstop"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tryAutoAuthenticateAfterSystemEvent(source: "screensaver.didstop")
            }
        })

        screenLockObservers.append(ws.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tryAutoAuthenticateAfterSystemEvent(source: "workspace.didWake")
            }
        })

        // Failsafe: when any window becomes key while SAM is locked, the
        // overlay is what the user is actually focused on. If notification
        // observers missed (rare race during screen-unlock transitions),
        // this catches the moment the overlay window takes focus and
        // triggers the prompt — so the *first* click on SAM unlocks.
        if windowKeyObserver == nil {
            windowKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                Task { @MainActor [weak self] in
                    guard let self, self.isLocked, !self.isAuthenticating else { return }
                    if note.object is LockOverlayWindow {
                        self.tryAutoAuthenticateAfterSystemEvent(source: "overlay.didBecomeKey")
                    }
                }
            }
        }

    }

    private func handleScreenEvent(source: String) {
        _ = source
        guard !isLocked else { return }
        lock()
    }

    // MARK: - Private Helpers

    /// Known auxiliary window identifiers that must hide when the app locks.
    /// The main WindowGroup has no explicit id, so it is excluded by omission.
    private static let auxiliaryWindowIDs: Set<String> = [
        "prompt-lab", "guide", "quick-note", "clipboard-capture", "compose-message"
    ]

    /// Hide all auxiliary windows (Settings, Prompt Lab, Guide, Quick Note,
    /// Compose, Clipboard) on lock without destroying their SwiftUI view trees.
    /// `orderOut(nil)` removes the window from screen but preserves the
    /// underlying state, so unlock is `orderFront(nil)` — instantaneous —
    /// instead of rebuilding the view hierarchy from scratch.
    private func hideAuxiliaryWindows() {
        hiddenWindowsAtLock = NSApplication.shared.windows.filter { window in
            guard window.isVisible else { return false }
            let id = window.identifier?.rawValue ?? ""
            let isSettings = id.contains("Settings")
            let isAuxiliary = Self.auxiliaryWindowIDs.contains(where: { id.contains($0) })
            return isSettings || isAuxiliary
        }
        for window in hiddenWindowsAtLock {
            window.orderOut(nil)
        }
    }

    /// Restore the auxiliary windows that were visible at lock time.
    /// Z-order intent is preserved by iterating in original visibility order.
    private func restoreVisibleWindows() {
        for window in hiddenWindowsAtLock {
            window.orderFront(nil)
        }
        hiddenWindowsAtLock.removeAll()
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
    }

    /// Remove the keyboard event monitor after unlock.
    private func removeKeyEventMonitor() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
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
