//
//  SystemNotificationService.swift
//  SAM
//
//  Created on February 27, 2026.
//  Manages macOS system notifications via UNUserNotificationCenter.
//  Used to notify the user when background tasks (like coaching plan generation) complete.
//

import Foundation
import UserNotifications
import AppKit
import os.log

/// Manages macOS system notifications (distinct from Foundation.NotificationCenter in-app events).
@MainActor
final class SystemNotificationService: NSObject, @preconcurrency UNUserNotificationCenterDelegate {

    static let shared = SystemNotificationService()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SystemNotificationService")

    // Notification category identifiers
    private static let planReadyCategory = "PLAN_READY"
    private static let viewPlanAction = "VIEW_PLAN"

    private override init() {
        super.init()
    }

    // MARK: - Setup

    /// Call once at app launch (from SAMAppDelegate.applicationDidFinishLaunching).
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // Define "View Plan" action button on the notification
        let viewAction = UNNotificationAction(
            identifier: Self.viewPlanAction,
            title: "View Plan",
            options: [.foreground]
        )

        let planCategory = UNNotificationCategory(
            identifier: Self.planReadyCategory,
            actions: [viewAction],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([planCategory])
        logger.info("System notification categories configured")
    }

    // MARK: - Permission

    /// Request notification permission lazily. Returns true if authorized.
    func requestPermissionIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                logger.info("Notification permission \(granted ? "granted" : "denied")")
                return granted
            } catch {
                logger.error("Notification permission request failed: \(error.localizedDescription)")
                return false
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Post Notifications

    /// Post a system notification when a coaching plan is ready.
    func postPlanReady(recommendationID: UUID, title: String) async {
        let granted = await requestPermissionIfNeeded()
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = "Coaching Plan Ready"
        content.body = "Your plan for \"\(title)\" is ready to review."
        content.sound = .default
        content.categoryIdentifier = Self.planReadyCategory
        content.userInfo = ["recommendationID": recommendationID.uuidString]

        let request = UNNotificationRequest(
            identifier: "plan-ready-\(recommendationID.uuidString)",
            content: content,
            trigger: nil  // Deliver immediately
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            logger.info("Plan ready notification posted for: \(title)")
        } catch {
            logger.error("Failed to post notification: \(error.localizedDescription)")
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show notification banner even when app is in foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .sound]
    }

    /// Handle notification tap — bring app to foreground and navigate to Strategic Insights.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let categoryID = response.notification.request.content.categoryIdentifier
        let userInfo = response.notification.request.content.userInfo

        guard categoryID == Self.planReadyCategory else { return }

        await MainActor.run {
            // Bring app to foreground
            NSApplication.shared.activate(ignoringOtherApps: true)

            // Post in-app notification to navigate to Business > Strategic tab
            NotificationCenter.default.post(
                name: .samNavigateToStrategicInsights,
                object: nil,
                userInfo: userInfo
            )
        }
    }
}
