//
//  DiagnosticsMailService.swift
//  SAM
//
//  Phase 0a — auto-send diagnostic JSON to sam@stillwaiting.org.
//
//  Pre-approved by the user via a Settings toggle. Drives Mail.app via
//  AppleScript to attach the JSON and send silently — same Automation
//  permission scope already used by ComposeService for outreach drafts.
//
//  This is a private-beta feature. The recipient is hard-coded to the
//  developer's inbox so Sarah's audits land where we can read them.
//  See memory `project_diagnostics_auto_send.md` — must be removed or
//  gated before any public release.
//

import AppKit
import Foundation
import os.log

@MainActor
@Observable
final class DiagnosticsMailService {

    static let shared = DiagnosticsMailService()
    private init() {}

    nonisolated let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "DiagnosticsMail")

    static let recipient = "sam@stillwaiting.org"

    // MARK: - Stored toggle

    private let enabledKey = "sam.diagnostics.autoSendEnabled"
    private let lastSentAtKey = "sam.diagnostics.lastSentAt"
    private let lastErrorKey = "sam.diagnostics.lastError"
    private let senderAddressKey = "sam.diagnostics.senderAddress"

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// From-address Mail.app should send as. Must match a configured Mail account.
    /// Empty → Mail.app uses its default account.
    var senderAddress: String {
        get { UserDefaults.standard.string(forKey: senderAddressKey) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: senderAddressKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: senderAddressKey)
            }
        }
    }

    var lastSentAt: Date? {
        let t = UserDefaults.standard.double(forKey: lastSentAtKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    var lastError: String? {
        UserDefaults.standard.string(forKey: lastErrorKey)
    }

    // MARK: - Public API

    /// Send a tiny test message so the macOS Automation prompt fires
    /// immediately on first opt-in. Returns true if Mail.app accepted
    /// the send (not a delivery confirmation).
    @discardableResult
    func sendTestEmail() async -> Bool {
        let body = """
        SAM diagnostics auto-send is now enabled.

        This is a one-line test to confirm Mail.app can deliver
        diagnostic reports to \(Self.recipient) without prompting.

        Sent: \(ISO8601DateFormatter().string(from: Date()))
        Host: \(Host.current().localizedName ?? "unknown")
        """
        return await send(
            subject: "[SAM Diagnostics] Test email",
            body: body,
            attachment: nil
        )
    }

    /// Send the dataset audit JSON. Caller passes the encoded report.
    @discardableResult
    func sendDatasetAudit(_ jsonData: Data) async -> Bool {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sam-dataset-audit-\(stamp).json")

        do {
            try jsonData.write(to: tempURL, options: .atomic)
        } catch {
            recordError("Could not write temp file: \(error.localizedDescription)")
            return false
        }

        let body = """
        Dataset audit attached.

        Generated: \(Date().formatted(date: .abbreviated, time: .standard))
        Host: \(Host.current().localizedName ?? "unknown")
        """

        let ok = await send(
            subject: "[SAM Diagnostics] Dataset audit \(stamp)",
            body: body,
            attachment: tempURL
        )

        // Best-effort cleanup. Mail.app holds the file open briefly; delete after a beat.
        Task.detached {
            try? await Task.sleep(for: .seconds(30))
            try? FileManager.default.removeItem(at: tempURL)
        }

        return ok
    }

    // MARK: - AppleScript send

    private func send(subject: String, body: String, attachment: URL?) async -> Bool {
        let script = buildScript(subject: subject, body: body, attachment: attachment)

        let success = await Task.detached(priority: .utility) { [logger] in
            guard let applescript = NSAppleScript(source: script) else {
                logger.error("DiagnosticsMail: failed to compile AppleScript")
                return (ok: false, message: "Could not compile AppleScript")
            }
            var errorDict: NSDictionary?
            applescript.executeAndReturnError(&errorDict)
            if let error = errorDict {
                let message = (error[NSAppleScript.errorMessage] as? String) ?? "\(error)"
                logger.error("DiagnosticsMail: AppleScript failed — \(message, privacy: .public)")
                return (ok: false, message: message)
            }
            return (ok: true, message: "")
        }.value

        if success.ok {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastSentAtKey)
            UserDefaults.standard.removeObject(forKey: lastErrorKey)
            logger.info("DiagnosticsMail: sent \"\(subject, privacy: .public)\"")
            return true
        } else {
            recordError(success.message)
            return false
        }
    }

    private func buildScript(subject: String, body: String, attachment: URL?) -> String {
        let escapedSubject = escape(subject)
        let escapedBody = escape(body)
        let recipient = Self.recipient
        let sender = senderAddress

        var props: [String] = [
            "subject:\"\(escapedSubject)\"",
            "content:\"\(escapedBody)\"",
            "visible:false"
        ]
        if !sender.isEmpty {
            props.append("sender:\"\(escape(sender))\"")
        }

        var lines: [String] = [
            "tell application \"Mail\"",
            "    set newMessage to make new outgoing message with properties {\(props.joined(separator: ", "))}",
            "    tell newMessage",
            "        make new to recipient at end of to recipients with properties {address:\"\(recipient)\"}"
        ]

        if let attachment {
            let escapedPath = escape(attachment.path)
            lines.append("        tell content")
            lines.append("            make new attachment with properties {file name:(POSIX file \"\(escapedPath)\")} at after the last paragraph")
            lines.append("        end tell")
        }

        lines.append("    end tell")
        // Small delay lets the attachment finish copying before send.
        if attachment != nil {
            lines.append("    delay 1")
        }
        lines.append("    send newMessage")
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    /// Escape a Swift string for safe inclusion in an AppleScript string literal.
    private func escape(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
    }

    private func recordError(_ message: String) {
        UserDefaults.standard.set(message, forKey: lastErrorKey)
    }
}
