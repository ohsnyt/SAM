//
//  ComposeService.swift
//  SAM
//
//  Created by Assistant on 2/24/26.
//  Phase O: Intelligent Actions
//
//  Handles sending messages and initiating calls via macOS system APIs.
//  Default mode: hand off to system apps (Messages, Mail, FaceTime).
//  Power user mode: send directly via AppleScript automation.
//

import Foundation
import AppKit
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ComposeService")

@MainActor
@Observable
final class ComposeService {

    // MARK: - Singleton

    static let shared = ComposeService()

    private init() {}

    // MARK: - Settings

    var directSendEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "directSendEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "directSendEnabled") }
    }

    // MARK: - System Handoff (Default Mode)

    /// Open Messages.app with recipient and body pre-filled via sms: URL scheme.
    /// Returns true if the URL was opened successfully.
    @discardableResult
    func composeIMessage(recipient: String, body: String) -> Bool {
        // Build sms: URL with body parameter
        var components = URLComponents()
        components.scheme = "sms"
        components.path = recipient
        // macOS Messages.app supports &body= on sms: scheme
        components.queryItems = [URLQueryItem(name: "body", value: body)]

        guard let url = components.url else {
            logger.error("Failed to build sms: URL for recipient \(recipient, privacy: .private)")
            return false
        }

        let opened = NSWorkspace.shared.open(url)
        if opened {
            logger.debug("Opened Messages.app for \(recipient, privacy: .private)")
        } else {
            logger.warning("sms: URL scheme failed — copying draft to clipboard")
            copyToClipboard(body)
        }
        return opened
    }

    /// Open Mail.app compose window via NSSharingService.
    /// Returns true if the service was performed successfully.
    @discardableResult
    func composeEmail(recipient: String, subject: String?, body: String) -> Bool {
        guard let service = NSSharingService(named: .composeEmail) else {
            logger.error("NSSharingService.composeEmail not available")
            return false
        }

        service.recipients = [recipient]
        service.subject = subject ?? ""

        // NSSharingService expects the body as the first item
        service.perform(withItems: [body])
        logger.debug("Opened Mail.app compose for \(recipient, privacy: .private)")
        return true
    }

    /// Initiate a phone call via tel: URL scheme (opens FaceTime).
    @discardableResult
    func initiateCall(recipient: String) -> Bool {
        let cleaned = recipient.filter { $0.isNumber || $0 == "+" }
        guard let url = URL(string: "tel:\(cleaned)") else {
            logger.error("Failed to build tel: URL for \(recipient, privacy: .private)")
            return false
        }

        let opened = NSWorkspace.shared.open(url)
        if opened {
            logger.debug("Initiated call to \(recipient, privacy: .private)")
        }
        return opened
    }

    /// Initiate a FaceTime video call.
    @discardableResult
    func initiateFaceTime(recipient: String) -> Bool {
        let cleaned = recipient.filter { $0.isNumber || $0 == "+" || $0 == "@" || $0 == "." }
        guard let url = URL(string: "facetime://\(cleaned)") else {
            logger.error("Failed to build facetime: URL for \(recipient, privacy: .private)")
            return false
        }

        let opened = NSWorkspace.shared.open(url)
        if opened {
            logger.debug("Initiated FaceTime to \(recipient, privacy: .private)")
        }
        return opened
    }

    // MARK: - Direct Send (Power User Mode)

    /// Send iMessage directly via AppleScript. Requires Automation permission
    /// and the `com.apple.MobileSMS` entry in the apple-events entitlement.
    func sendDirectIMessage(recipient: String, body: String) async -> Bool {
        let escaped = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let recipientEscaped = recipient
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        // macOS 13+ (Ventura): Apple renamed "service" to "account" in Messages' AppleScript dictionary
        let script = """
            tell application "Messages"
                set targetService to 1st account whose service type = iMessage
                set targetBuddy to buddy "\(recipientEscaped)" of targetService
                send "\(escaped)" to targetBuddy
            end tell
            """

        return await runAppleScript(script, label: "iMessage to \(recipient)")
    }

    /// Send email directly via AppleScript. Requires Automation permission.
    func sendDirectEmail(recipient: String, subject: String?, body: String) async -> Bool {
        let escapedBody = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedSubject = (subject ?? "")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedRecipient = recipient
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
            tell application "Mail"
                set newMessage to make new outgoing message with properties {subject:"\(escapedSubject)", content:"\(escapedBody)", visible:false}
                tell newMessage
                    make new to recipient at end of to recipients with properties {address:"\(escapedRecipient)"}
                end tell
                send newMessage
            end tell
            """

        return await runAppleScript(script, label: "Email to \(recipient)")
    }

    // MARK: - WhatsApp

    /// Open WhatsApp via the wa.me deep link with an optional pre-filled message.
    /// The phone number should contain only digits (no +, dashes, or spaces).
    @discardableResult
    func composeWhatsApp(phone: String, body: String) -> Bool {
        let digits = phone.filter(\.isNumber)
        guard !digits.isEmpty else {
            logger.error("Empty phone number for WhatsApp compose")
            return false
        }

        let encoded = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://wa.me/\(digits)?text=\(encoded)"

        if let url = URL(string: urlString), NSWorkspace.shared.open(url) {
            logger.debug("Opened WhatsApp for \(digits, privacy: .private)")
            return true
        }

        // Fallback: try whatsapp:// scheme (desktop app)
        let appURLString = "whatsapp://send?phone=\(digits)&text=\(encoded)"
        if let url = URL(string: appURLString), NSWorkspace.shared.open(url) {
            logger.debug("Opened WhatsApp desktop app for \(digits, privacy: .private)")
            return true
        }

        logger.warning("WhatsApp URL schemes failed — copying draft to clipboard")
        copyToClipboard(body)
        return false
    }

    // MARK: - LinkedIn

    /// Open the person's LinkedIn messaging overlay in the default browser.
    /// Appends `/overlay/new-message/` to the profile URL. Falls back to the profile page.
    @discardableResult
    func openLinkedInMessaging(profileURL: String) -> Bool {
        let normalized = profileURL.hasSuffix("/")
            ? String(profileURL.dropLast())
            : profileURL
        let withScheme = normalized.hasPrefix("http") ? normalized : "https://\(normalized)"
        let messagingString = "\(withScheme)/overlay/new-message/"

        if let url = URL(string: messagingString), NSWorkspace.shared.open(url) {
            logger.debug("Opened LinkedIn messaging for \(profileURL, privacy: .private)")
            return true
        }
        // Fallback: open profile page directly
        if let url = URL(string: withScheme), NSWorkspace.shared.open(url) {
            logger.warning("Messaging overlay URL failed — opened profile page instead")
            return true
        }
        logger.error("Failed to open LinkedIn URL: \(profileURL, privacy: .private)")
        return false
    }

    // MARK: - Generic Social Profile

    /// Open any social profile URL in the default browser.
    @discardableResult
    func openSocialProfile(url: String) -> Bool {
        let withScheme = url.hasPrefix("http") ? url : "https://\(url)"
        if let parsed = URL(string: withScheme), NSWorkspace.shared.open(parsed) {
            logger.debug("Opened social profile: \(url, privacy: .private)")
            return true
        }
        logger.error("Failed to open social profile URL: \(url, privacy: .private)")
        return false
    }

    // MARK: - Helpers

    func copyToClipboard(_ text: String) {
        ClipboardSecurity.copy(text, clearAfter: 60)
        logger.debug("Draft copied to clipboard (auto-clear in 60s)")
    }

    private func runAppleScript(_ source: String, label: String) async -> Bool {
        guard let script = NSAppleScript(source: source) else {
            logger.error("Failed to create AppleScript for \(label, privacy: .public)")
            return false
        }

        var errorDict: NSDictionary?
        script.executeAndReturnError(&errorDict)

        if let error = errorDict {
            logger.error("AppleScript failed for \(label, privacy: .public): \(error)")
            return false
        }

        logger.debug("AppleScript succeeded: \(label, privacy: .public)")
        return true
    }
}
