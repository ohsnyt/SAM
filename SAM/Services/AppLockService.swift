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

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "AppLockService")

@MainActor
@Observable
final class AppLockService {

    static let shared = AppLockService()

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

    // MARK: - Initializer

    private init() {
        isLocked = true
    }

    // MARK: - Authentication

    /// Authenticate using Touch ID with system password fallback. Unlocks the app on success.
    func authenticate() {
        guard isLocked else { return }
        guard !isAuthenticating else { return }

        isAuthenticating = true
        authError = nil

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

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

    /// Immediately lock the app and close auxiliary windows (Settings, Guide, etc.).
    func lock() {
        isLocked = true
        closeAuxiliaryWindows()
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
            logger.debug("App locked — inactive for \(Int(elapsed / 60)) minutes (timeout: \(self.lockTimeoutMinutes)m)")
        }
    }

    // MARK: - Launch Configuration

    /// Configure lock state on app launch. Always starts locked.
    func configureOnLaunch() {
        isLocked = true
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
}
