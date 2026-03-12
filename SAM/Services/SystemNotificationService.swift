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
final class SystemNotificationService: NSObject, UNUserNotificationCenterDelegate {

    static let shared = SystemNotificationService()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SystemNotificationService")

    // Notification category identifiers
    private static let planReadyCategory = "PLAN_READY"
    private static let viewPlanAction = "VIEW_PLAN"
    private static let meetingPrepCategory = "MEETING_PREP"
    private static let viewMeetingPrepAction = "VIEW_MEETING_PREP"
    private static let substackExportCategory = "SUBSTACK_EXPORT"
    private static let openSubstackExportAction = "OPEN_SUBSTACK_EXPORT"
    private static let remindSubstackLaterAction = "REMIND_SUBSTACK_LATER"
    private static let linkedInExportCategory = "LINKEDIN_EXPORT"
    private static let openLinkedInExportAction = "OPEN_LINKEDIN_EXPORT"
    private static let remindLinkedInLaterAction = "REMIND_LINKEDIN_LATER"
    private static let facebookExportCategory = "FACEBOOK_EXPORT"
    private static let openFacebookExportAction = "OPEN_FACEBOOK_EXPORT"
    private static let remindFacebookLaterAction = "REMIND_FACEBOOK_LATER"
    private static let unknownSenderRSVPCategory = "UNKNOWN_SENDER_RSVP"
    private static let viewUnknownSenderAction = "VIEW_UNKNOWN_SENDER"
    private static let eventReminderCategory = "EVENT_REMINDER"
    private static let viewEventRemindersAction = "VIEW_EVENT_REMINDERS"

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

        // Meeting Prep category
        let viewMeetingAction = UNNotificationAction(
            identifier: Self.viewMeetingPrepAction,
            title: "View Briefing",
            options: [.foreground]
        )

        let meetingCategory = UNNotificationCategory(
            identifier: Self.meetingPrepCategory,
            actions: [viewMeetingAction],
            intentIdentifiers: [],
            options: []
        )

        // Substack Export category
        let openExportAction = UNNotificationAction(
            identifier: Self.openSubstackExportAction,
            title: "Open Export Page",
            options: [.foreground]
        )

        let remindLaterAction = UNNotificationAction(
            identifier: Self.remindSubstackLaterAction,
            title: "Remind Me Later",
            options: []
        )

        let substackCategory = UNNotificationCategory(
            identifier: Self.substackExportCategory,
            actions: [openExportAction, remindLaterAction],
            intentIdentifiers: [],
            options: []
        )

        // LinkedIn Export category
        let openLinkedInExportAction = UNNotificationAction(
            identifier: Self.openLinkedInExportAction,
            title: "Open Download Page",
            options: [.foreground]
        )

        let remindLinkedInLaterAction = UNNotificationAction(
            identifier: Self.remindLinkedInLaterAction,
            title: "Remind Me Later",
            options: []
        )

        let linkedInCategory = UNNotificationCategory(
            identifier: Self.linkedInExportCategory,
            actions: [openLinkedInExportAction, remindLinkedInLaterAction],
            intentIdentifiers: [],
            options: []
        )

        // Facebook Export category
        let openFacebookExportAction = UNNotificationAction(
            identifier: Self.openFacebookExportAction,
            title: "Open Download Page",
            options: [.foreground]
        )

        let remindFacebookLaterAction = UNNotificationAction(
            identifier: Self.remindFacebookLaterAction,
            title: "Remind Me Later",
            options: []
        )

        let facebookCategory = UNNotificationCategory(
            identifier: Self.facebookExportCategory,
            actions: [openFacebookExportAction, remindFacebookLaterAction],
            intentIdentifiers: [],
            options: []
        )

        // Unknown Sender RSVP category
        let viewUnknownSenderAction = UNNotificationAction(
            identifier: Self.viewUnknownSenderAction,
            title: "View Event",
            options: [.foreground]
        )

        let unknownSenderCategory = UNNotificationCategory(
            identifier: Self.unknownSenderRSVPCategory,
            actions: [viewUnknownSenderAction],
            intentIdentifiers: [],
            options: []
        )

        // Event Reminder category
        let viewRemindersAction = UNNotificationAction(
            identifier: Self.viewEventRemindersAction,
            title: "View Reminders",
            options: [.foreground]
        )

        let eventReminderCategory = UNNotificationCategory(
            identifier: Self.eventReminderCategory,
            actions: [viewRemindersAction],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([planCategory, meetingCategory, substackCategory, linkedInCategory, facebookCategory, unknownSenderCategory, eventReminderCategory])
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

    /// Post a system notification for an upcoming meeting briefing.
    func postMeetingReminder(briefing: MeetingBriefing) async {
        let granted = await requestPermissionIfNeeded()
        guard granted else { return }

        let minutesUntil = max(1, Int(briefing.startsAt.timeIntervalSinceNow / 60))

        let content = UNMutableNotificationContent()
        content.title = "Meeting in \(minutesUntil) min"
        content.subtitle = briefing.title
        content.sound = .default
        content.categoryIdentifier = Self.meetingPrepCategory
        content.userInfo = ["eventID": briefing.eventID.uuidString]

        // Body: attendee names + first talking point
        var bodyParts: [String] = []
        let attendeeNames = briefing.attendees.prefix(3).map(\.displayName)
        if !attendeeNames.isEmpty {
            bodyParts.append("With: \(attendeeNames.joined(separator: ", "))")
        }
        if let firstPoint = briefing.talkingPoints.first {
            bodyParts.append(firstPoint)
        }
        content.body = bodyParts.joined(separator: "\n")

        let request = UNNotificationRequest(
            identifier: "meeting-prep-\(briefing.eventID.uuidString)",
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            logger.info("Meeting prep notification posted for: \(briefing.title)")
        } catch {
            logger.error("Failed to post meeting prep notification: \(error.localizedDescription)")
        }
    }

    /// Post a system notification when a Substack export is ready to download.
    func postSubstackExportReady(downloadURL: URL, triggerDate: Date? = nil) async {
        let granted = await requestPermissionIfNeeded()
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = "Substack data export ready to download"
        content.body = "SAM detected the export instructions email. Open Substack to download the archive."
        content.sound = .default
        content.categoryIdentifier = Self.substackExportCategory
        content.userInfo = ["downloadURL": downloadURL.absoluteString]

        var trigger: UNNotificationTrigger?
        if let triggerDate {
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: triggerDate
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        }

        let request = UNNotificationRequest(
            identifier: "substack-export-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            logger.info("Substack export notification posted (scheduled: \(triggerDate != nil))")
        } catch {
            logger.error("Failed to post Substack export notification: \(error.localizedDescription)")
        }
    }

    /// Post a system notification when a LinkedIn export is ready to download.
    func postLinkedInExportReady(downloadURL: URL, triggerDate: Date? = nil) async {
        let granted = await requestPermissionIfNeeded()
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = "LinkedIn data export ready to download"
        content.body = "SAM detected the export email. Open LinkedIn to download the archive."
        content.sound = .default
        content.categoryIdentifier = Self.linkedInExportCategory
        content.userInfo = ["downloadURL": downloadURL.absoluteString]

        var trigger: UNNotificationTrigger?
        if let triggerDate {
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: triggerDate
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        }

        let request = UNNotificationRequest(
            identifier: "linkedin-export-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            logger.info("LinkedIn export notification posted (scheduled: \(triggerDate != nil))")
        } catch {
            logger.error("Failed to post LinkedIn export notification: \(error.localizedDescription)")
        }
    }

    /// Post a system notification when a Facebook export is ready to download.
    func postFacebookExportReady(downloadURL: URL, triggerDate: Date? = nil) async {
        let granted = await requestPermissionIfNeeded()
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = "Facebook data export ready to download"
        content.body = "SAM detected the export email. Open Facebook to download the archive."
        content.sound = .default
        content.categoryIdentifier = Self.facebookExportCategory
        content.userInfo = ["downloadURL": downloadURL.absoluteString]

        var trigger: UNNotificationTrigger?
        if let triggerDate {
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: triggerDate
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        }

        let request = UNNotificationRequest(
            identifier: "facebook-export-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            logger.info("Facebook export notification posted (scheduled: \(triggerDate != nil))")
        } catch {
            logger.error("Failed to post Facebook export notification: \(error.localizedDescription)")
        }
    }

    /// Post a system notification when an unknown sender's message matches an event RSVP.
    func postUnknownSenderRSVP(senderHandle: String, eventTitle: String, eventID: UUID, autoReplied: Bool) async {
        let granted = await requestPermissionIfNeeded()
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = autoReplied ? "Auto-replied to unknown RSVP" : "Unknown sender RSVP detected"
        content.body = "\(senderHandle) messaged about \"\(eventTitle)\""
        if autoReplied {
            content.subtitle = "Holding reply sent"
        }
        content.sound = .default
        content.categoryIdentifier = Self.unknownSenderRSVPCategory
        content.userInfo = ["eventID": eventID.uuidString]

        let request = UNNotificationRequest(
            identifier: "unknown-rsvp-\(eventID.uuidString)-\(senderHandle.hashValue)",
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            logger.info("Unknown sender RSVP notification posted for event: \(eventTitle)")
        } catch {
            logger.error("Failed to post unknown sender RSVP notification: \(error.localizedDescription)")
        }
    }

    /// Post a system notification for event reminders (sent or ready to review).
    func postEventReminder(eventTitle: String, eventID: UUID, attendeeCount: Int, autoSent: Bool) async {
        let granted = await requestPermissionIfNeeded()
        guard granted else { return }

        let content = UNMutableNotificationContent()
        if autoSent {
            content.title = "Event reminders sent"
            content.body = "Sent reminders to \(attendeeCount) \(attendeeCount == 1 ? "attendee" : "attendees") for \"\(eventTitle)\""
        } else {
            content.title = "Event reminders ready to review"
            content.body = "\(attendeeCount) reminder \(attendeeCount == 1 ? "draft" : "drafts") for \"\(eventTitle)\""
        }
        content.sound = .default
        content.categoryIdentifier = Self.eventReminderCategory
        content.userInfo = ["eventID": eventID.uuidString]

        let request = UNNotificationRequest(
            identifier: "event-reminder-\(eventID.uuidString)-\(Date.now.timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            logger.info("Event reminder notification posted for: \(eventTitle)")
        } catch {
            logger.error("Failed to post event reminder notification: \(error.localizedDescription)")
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
        // Capture userInfo as Sendable string dictionary before crossing actor boundary
        let rawUserInfo = response.notification.request.content.userInfo
        let sendableUserInfo = rawUserInfo.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String {
                result[key] = value
            }
        }

        await MainActor.run {
            // Bring app to foreground
            NSApplication.shared.activate(ignoringOtherApps: true)

            switch categoryID {
            case Self.planReadyCategory:
                NotificationCenter.default.post(
                    name: .samNavigateToStrategicInsights,
                    object: nil,
                    userInfo: sendableUserInfo
                )
            case Self.meetingPrepCategory:
                // Navigate to Today view and expand meeting prep section
                NotificationCenter.default.post(
                    name: .samNavigateToSection,
                    object: nil,
                    userInfo: ["section": "today"]
                )
                // Small delay so sidebar navigates before expanding
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.post(
                        name: .samExpandMeetingPrep,
                        object: nil
                    )
                }

            case Self.substackExportCategory:
                let actionID = response.actionIdentifier
                if actionID == Self.openSubstackExportAction {
                    if let urlString = sendableUserInfo["downloadURL"],
                       let url = URL(string: urlString) {
                        NSWorkspace.shared.open(url)
                    }
                    SubstackImportCoordinator.shared.startFileWatcher()
                } else if actionID == Self.remindSubstackLaterAction {
                    Task {
                        await SubstackImportCoordinator.shared.scheduleReminder()
                    }
                } else {
                    if let urlString = sendableUserInfo["downloadURL"],
                       let url = URL(string: urlString) {
                        NSWorkspace.shared.open(url)
                    }
                    SubstackImportCoordinator.shared.startFileWatcher()
                }

            case Self.linkedInExportCategory:
                let actionID = response.actionIdentifier
                if actionID == Self.openLinkedInExportAction {
                    if let urlString = sendableUserInfo["downloadURL"],
                       let url = URL(string: urlString) {
                        NSWorkspace.shared.open(url)
                    }
                    LinkedInImportCoordinator.shared.startFileWatcher()
                } else if actionID == Self.remindLinkedInLaterAction {
                    Task {
                        await LinkedInImportCoordinator.shared.scheduleReminder()
                    }
                } else {
                    // Default tap — open download URL and start file watcher
                    if let urlString = sendableUserInfo["downloadURL"],
                       let url = URL(string: urlString) {
                        NSWorkspace.shared.open(url)
                    }
                    LinkedInImportCoordinator.shared.startFileWatcher()
                }

            case Self.facebookExportCategory:
                let actionID = response.actionIdentifier
                if actionID == Self.openFacebookExportAction {
                    if let urlString = sendableUserInfo["downloadURL"],
                       let url = URL(string: urlString) {
                        NSWorkspace.shared.open(url)
                    }
                    FacebookImportCoordinator.shared.startFileWatcher()
                } else if actionID == Self.remindFacebookLaterAction {
                    Task {
                        await FacebookImportCoordinator.shared.scheduleReminder()
                    }
                } else {
                    // Default tap — open download URL and start file watcher
                    if let urlString = sendableUserInfo["downloadURL"],
                       let url = URL(string: urlString) {
                        NSWorkspace.shared.open(url)
                    }
                    FacebookImportCoordinator.shared.startFileWatcher()
                }

            case Self.unknownSenderRSVPCategory, Self.eventReminderCategory:
                // Navigate to the event — post section navigation to events
                if let eventIDString = sendableUserInfo["eventID"] {
                    NotificationCenter.default.post(
                        name: .samNavigateToSection,
                        object: nil,
                        userInfo: ["section": "events", "eventID": eventIDString]
                    )
                }

            default:
                break
            }
        }
    }
}
