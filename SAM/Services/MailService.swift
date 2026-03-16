//
//  MailService.swift
//  SAM_crm
//
//  Email Integration - Mail.app AppleScript Bridge
//
//  Actor-isolated service that reads email from Mail.app via NSAppleScript.
//  Returns only Sendable DTOs. Never stores raw message bodies.
//

import Foundation
import os.log

/// Lightweight account info from Mail.app for the Settings UI picker.
struct MailAccountDTO: Sendable, Identifiable {
    let id: String            // Mail.app account name (unique per account)
    let name: String          // e.g. "iCloud", "Gmail - work@example.com"
    let emailAddresses: [String]
}

/// Which mailbox to scan within a Mail.app account.
enum MailboxTarget: String, Sendable {
    case inbox
    case sent
}

/// Lightweight metadata from a Mail.app message (Phase 1 metadata sweep).
/// Top-level so MailImportCoordinator can partition by sender before body fetch.
struct MessageMeta: Sendable {
    let mailID: Int32
    let messageID: String
    let subject: String
    let sender: String            // raw "Name <email>"
    let senderEmail: String       // extracted, lowercased
    let date: Date
    let accountName: String       // resolved account name for body fetch
    let isLikelyMarketing: Bool   // detected from List-Unsubscribe / List-ID / Precedence headers (no body needed)
    let mailboxTarget: MailboxTarget  // which mailbox this message came from
}

/// Actor-isolated service for reading email from Mail.app via NSAppleScript.
actor MailService {
    static let shared = MailService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "MailService")

    /// Maximum number of message bodies to fetch per import (bounds runtime).
    private let maxBodyFetches = 200

    private init() {}

    // MARK: - Access Check

    /// Result of a Mail.app access check, distinguishing permanent permission
    /// loss from transient failures (Mail busy, not running, timeout).
    enum AccessCheckResult: Sendable {
        /// Mail.app responded successfully.
        case ok
        /// Automation permission has been revoked — onboarding should re-run.
        case permissionDenied(String)
        /// Transient failure (Mail not running, busy, timeout) — do NOT reset onboarding.
        case transientError(String)
    }

    /// Check if Mail.app is available and we have automation permission.
    /// Returns nil on success, error message on failure.
    func checkAccess() async -> String? {
        switch await checkAccessDetailed() {
        case .ok: return nil
        case .permissionDenied(let msg): return msg
        case .transientError(let msg): return msg
        }
    }

    /// Detailed access check that distinguishes permission denial from transient errors.
    func checkAccessDetailed() async -> AccessCheckResult {
        let script = """
        tell application "Mail"
            with timeout of 10 seconds
                return name of first account
            end timeout
        end tell
        """
        let (stdout, error) = await executeOsascript(script, timeout: 15)
        if let error {
            if error.contains("-1743") || error.contains("not allowed") {
                return .permissionDenied("SAM does not have permission to control Mail.app. Please grant access in System Settings → Privacy & Security → Automation.")
            }
            // -600 = app not running, -609 = connection invalid, -1712 = timeout
            // These are transient — Mail may be busy, not launched, or overwhelmed
            return .transientError("Cannot access Mail.app: \(error)")
        }
        if stdout == nil || stdout?.isEmpty == true {
            return .transientError("No Mail accounts found. Configure an account in Mail.app first.")
        }
        return .ok
    }

    // MARK: - Fetch Accounts

    /// Fetch available Mail.app accounts.
    /// Output format: one line per account: "accountName \t email1,email2,..."
    func fetchAccounts() async -> [MailAccountDTO] {
        let script = """
        tell application "Mail"
            with timeout of 15 seconds
                set output to ""
                set lineFeed to ASCII character 10
                repeat with acct in every account
                    set acctName to name of acct
                    set acctEmails to email addresses of acct
                    set emailStr to ""
                    repeat with e in acctEmails
                        if emailStr is not "" then set emailStr to emailStr & ","
                        set emailStr to emailStr & e
                    end repeat
                    set output to output & acctName & tab & emailStr & lineFeed
                end repeat
                return output
            end timeout
        end tell
        """
        let (stdout, osError) = await executeOsascript(script, timeout: 20)
        if let osError {
            logger.error("Failed to fetch accounts: \(osError, privacy: .public)")
            return []
        }
        guard let output = stdout, !output.isEmpty else { return [] }

        var accounts: [MailAccountDTO] = []
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            let name = parts[0]
            let emails: [String]
            if parts.count > 1 && !parts[1].isEmpty {
                emails = parts[1].split(separator: ",").map { String($0) }
            } else if name.contains("@") {
                emails = [name]
            } else {
                emails = []
            }

            let accountID = emails.first ?? name
            accounts.append(MailAccountDTO(
                id: accountID,
                name: name,
                emailAddresses: emails
            ))
            logger.debug("Account: '\(name, privacy: .private)' emails=\(emails, privacy: .private)")
        }

        logger.debug("Found \(accounts.count) Mail.app accounts")
        return accounts
    }

    // MARK: - Fetch Metadata (Phase 1 — fast)

    /// Phase 1: Fast metadata-only sweep of a Mail.app mailbox (inbox or sent).
    /// Returns (metas, warningMessage). Warning is non-nil if accounts had errors.
    ///
    /// Runs via `osascript` subprocess with a hard kill timeout so Mail.app hangs
    /// can't block SAM indefinitely. Outputs tab-delimited rows (one per message)
    /// which is far lighter for Mail to produce than nested AppleScript lists.
    /// Marketing detection uses Swift-side heuristics instead of per-message header checks.
    func fetchMetadata(
        accountIDs: [String],
        since: Date,
        mailbox: MailboxTarget = .inbox
    ) async throws -> ([MessageMeta], String?) {
        guard !accountIDs.isEmpty else { return ([], nil) }

        let days = max(1, Calendar.current.dateComponents([.day], from: since, to: Date()).day ?? 30)
        var allMetas: [MessageMeta] = []
        var accountWarnings: [String] = []

        let dateField = mailbox == .inbox ? "date received" : "date sent"
        let debugLabel = mailbox == .inbox ? "__inbox_debug__" : "__sent_debug__"

        for accountID in accountIDs {
            guard !Task.isCancelled else { break }

            let escapedEmail = accountID.replacingOccurrences(of: "\"", with: "\\\"")
            let mbxResolution = mailboxResolutionScript(for: mailbox)

            // Tab-delimited output: one line per message, fields separated by \t
            // This is much lighter for Mail to produce than nested AppleScript lists.
            // Format: id \t messageID \t subject \t sender \t dateString
            let metadataScript = """
            tell application "Mail"
                with timeout of 90 seconds
                    set targetEmail to "\(escapedEmail)"
                    set cutoff to (current date) - (\(days) * days)
                    set matchedName to ""
                    set maxMsgs to \(maxBodyFetches)
                    set lineFeed to ASCII character 10

                    repeat with acct in every account
                        try
                            set acctMatch to false
                            if (email addresses of acct) contains targetEmail then
                                set acctMatch to true
                            else if (name of acct) is targetEmail then
                                set acctMatch to true
                            end if
                            if acctMatch then
                                set matchedName to name of acct
                                \(mbxResolution)
                                if mbx is missing value then
                                    return "\(debugLabel)" & tab & matchedName & tab & "all mailbox methods failed"
                                end if
                                set filteredMsgs to (every message of mbx whose \(dateField) > cutoff)
                                set msgCount to count of filteredMsgs
                                if msgCount is 0 then
                                    return "__empty__" & tab & matchedName
                                end if
                                -- Cap the result set
                                if msgCount > maxMsgs then
                                    set filteredMsgs to items 1 thru maxMsgs of filteredMsgs
                                    set msgCount to maxMsgs
                                end if
                                -- Build tab-delimited output, one message per line
                                set output to "__data__" & tab & matchedName & tab & (msgCount as text) & lineFeed
                                repeat with i from 1 to msgCount
                                    try
                                        set msg to item i of filteredMsgs
                                        set msgID to id of msg
                                        set msgMsgID to message id of msg
                                        set msgSubj to subject of msg
                                        set msgSender to sender of msg
                                        set msgDate to \(dateField) of msg
                                        -- Format date as Unix timestamp for reliable parsing
                                        set epochRef to current date
                                        set year of epochRef to 2001
                                        set month of epochRef to 1
                                        set day of epochRef to 1
                                        set time of epochRef to 0
                                        set unixDate to (msgDate - epochRef)
                                        set output to output & (msgID as text) & tab & msgMsgID & tab & msgSubj & tab & msgSender & tab & (unixDate as text) & lineFeed
                                    end try
                                end repeat
                                return output
                            end if
                        end try
                    end repeat
                    return "__not_found__"
                end timeout
            end tell
            """

            let (stdout, osError) = await executeOsascript(metadataScript, timeout: 120)
            if let osError {
                logger.warning("Metadata sweep failed for \(accountID, privacy: .private): \(osError, privacy: .public)")
                accountWarnings.append("'\(accountID)': \(osError)")
                continue
            }
            guard let output = stdout, !output.isEmpty else { continue }

            // Parse sentinel responses (single-line)
            if output.hasPrefix("__not_found__") {
                logger.warning("No account found with email \(accountID, privacy: .private)")
                accountWarnings.append("No Mail account found for '\(accountID)'")
                continue
            }
            if output.hasPrefix("__empty__") {
                let parts = output.split(separator: "\t", maxSplits: 1)
                let acctName = parts.count > 1 ? String(parts[1]) : "?"
                logger.debug("Account '\(acctName, privacy: .private)' matched, no messages in date range")
                continue
            }
            if output.hasPrefix(debugLabel) {
                let parts = output.split(separator: "\t", maxSplits: 2)
                let acctName = parts.count > 1 ? String(parts[1]) : "?"
                let errDetail = parts.count > 2 ? String(parts[2]) : "unknown"
                let mbxLabel = mailbox == .sent ? "sent" : "inbox"
                logger.error("Account '\(acctName, privacy: .private)' matched but \(mbxLabel) not accessible: \(errDetail, privacy: .public)")
                accountWarnings.append("Account '\(acctName)' \(mbxLabel) not accessible: \(errDetail)")
                continue
            }

            // Parse __data__ response: first line is header, subsequent lines are messages
            let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard let headerLine = lines.first, headerLine.hasPrefix("__data__") else { continue }

            let headerParts = headerLine.split(separator: "\t", maxSplits: 2)
            let resolvedAccountName = headerParts.count > 1 ? String(headerParts[1]) : accountID

            logger.debug("Account '\(resolvedAccountName, privacy: .private)' (email: \(accountID, privacy: .private)): \(lines.count - 1) messages in date range")

            for line in lines.dropFirst() {
                let fields = line.components(separatedBy: "\t")
                guard fields.count >= 5 else { continue }

                let mailID = Int32(fields[0]) ?? 0
                let messageID = fields[1]
                let subject = fields[2].isEmpty ? "(No Subject)" : fields[2]
                let sender = fields[3]
                // Parse Unix timestamp (seconds since 2001-01-01, AppleScript epoch)
                let dateVal: Date
                if let interval = TimeInterval(fields[4]) {
                    dateVal = Date(timeIntervalSinceReferenceDate: interval)
                } else {
                    dateVal = Date()
                }
                let senderEmail = Self.extractEmail(from: sender)
                let isLikelyMarketing = Self.isLikelyMarketingSender(email: senderEmail)

                allMetas.append(MessageMeta(
                    mailID: mailID,
                    messageID: messageID,
                    subject: subject,
                    sender: sender,
                    senderEmail: senderEmail,
                    date: dateVal,
                    accountName: resolvedAccountName,
                    isLikelyMarketing: isLikelyMarketing,
                    mailboxTarget: mailbox
                ))
            }
        }

        logger.debug("Metadata sweep complete: \(allMetas.count) messages from \(accountIDs.count) accounts")
        let warning = accountWarnings.isEmpty ? nil : accountWarnings.joined(separator: "\n")
        return (allMetas, warning)
    }

    // MARK: - Marketing Detection (Swift-side)

    /// Common local-parts used by marketing/bulk senders.
    private static let marketingLocalParts: Set<String> = [
        "noreply", "no-reply", "no_reply",
        "newsletter", "newsletters",
        "marketing", "promotions", "promo",
        "info", "updates", "news",
        "notifications", "notification",
        "mailer", "mailer-daemon",
        "bounce", "bounces",
        "donotreply", "do-not-reply", "do_not_reply",
        "unsubscribe",
        "digest", "weekly", "daily",
        "campaign", "campaigns",
        "announce", "announcements",
        "bulk", "blast",
        "support", "feedback",
    ]

    /// Common domains used exclusively for marketing/transactional bulk email.
    private static let marketingDomains: Set<String> = [
        "mailchimp.com", "mandrillapp.com",
        "sendgrid.net", "sendgrid.com",
        "constantcontact.com", "ctctmail.com",
        "mailgun.org", "mailgun.com",
        "amazonses.com",
        "salesforce.com", "exacttarget.com",
        "hubspot.com", "hubspotmail.com",
        "marketo.com", "mktomail.com",
        "klaviyo.com",
        "postmarkapp.com",
        "sendinblue.com", "brevo.com",
        "campaignmonitor.com", "cmail1.com", "cmail2.com",
        "substack.com", "substackmail.com",
        "beehiiv.com",
        "convertkit.com",
        "drip.com",
        "getresponse.com",
        "aweber.com",
        "infusionsoft.com",
        "activecampaign.com",
        "intercom.io", "intercom-mail.com",
        "zendesk.com",
    ]

    /// Detect likely marketing/bulk email by sender address heuristics.
    /// Replaces per-message AppleScript header checks (List-Unsubscribe, List-ID, Precedence)
    /// to avoid hammering Mail.app with individual Apple Events.
    static func isLikelyMarketingSender(email: String) -> Bool {
        let parts = email.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return false }
        let localPart = String(parts[0]).lowercased()
        let domain = String(parts[1]).lowercased()

        // Check domain against known bulk-email infrastructure
        if marketingDomains.contains(domain) { return true }

        // Check if the domain is a subdomain of a known marketing domain
        for mktDomain in marketingDomains {
            if domain.hasSuffix(".\(mktDomain)") { return true }
        }

        // Check local-part against common marketing sender patterns
        if marketingLocalParts.contains(localPart) { return true }

        return false
    }

    // MARK: - Fetch Bodies (Phase 2 — slow)

    /// Seconds to pause between single-message body fetches so Mail.app can
    /// service its own UI events and IMAP work.
    private let interBodyDelay: TimeInterval = 1.0

    /// Phase 2: Fetch message bodies + recipients one at a time via osascript.
    /// Each fetch runs in a subprocess with a hard 30s kill timeout.
    /// A delay between fetches lets Mail.app stay responsive.
    func fetchBodies(
        for metas: [MessageMeta],
        filterRules: [MailFilterRule],
        mailbox: MailboxTarget = .inbox
    ) async -> [EmailDTO] {
        guard !metas.isEmpty else { return [] }

        var allEmails: [EmailDTO] = []
        let toFetch = Array(metas.prefix(maxBodyFetches))

        // Group metas by account
        let byAccount = Dictionary(grouping: toFetch, by: \.accountName)

        for (accountName, accountMetas) in byAccount {
            let escapedAcctName = accountName.replacingOccurrences(of: "\"", with: "\\\"")
            let mbxResolution = mailboxResolutionScript(for: mailbox)
            let mbxErrorLabel = mailbox == .sent ? "sent mailbox" : "inbox"

            for (index, meta) in accountMetas.enumerated() {
                guard !Task.isCancelled else { break }

                // Throttle between fetches
                if index > 0 {
                    try? await Task.sleep(for: .seconds(interBodyDelay))
                }

                // Fetch one message body via osascript with hard timeout.
                // Output format: recipientEmails \t ccEmails \t readStatus \n body
                // Recipients/CCs are comma-separated within their field.
                let bodyScript = """
                tell application "Mail"
                    with timeout of 30 seconds
                        set acct to first account whose name is "\(escapedAcctName)"
                        \(mbxResolution)
                        if mbx is missing value then error "No \(mbxErrorLabel) found"
                        set m to (first message of mbx whose id is \(meta.mailID))
                        set msgContent to content of m
                        set toAddrs to address of every to recipient of m
                        set ccAddrs to address of every cc recipient of m
                        set isRead to read status of m
                        -- Build comma-separated recipient lists
                        set toStr to ""
                        repeat with a in toAddrs
                            if toStr is not "" then set toStr to toStr & ","
                            set toStr to toStr & a
                        end repeat
                        set ccStr to ""
                        repeat with a in ccAddrs
                            if ccStr is not "" then set ccStr to ccStr & ","
                            set ccStr to ccStr & a
                        end repeat
                        set readStr to "true"
                        if not isRead then set readStr to "false"
                        -- First line: metadata; remaining lines: body
                        return toStr & tab & ccStr & tab & readStr & (ASCII character 10) & msgContent
                    end timeout
                end tell
                """

                let (stdout, osError) = await executeOsascript(bodyScript, timeout: 45)
                if let osError {
                    logger.warning("Body fetch failed for message \(meta.mailID): \(osError, privacy: .public)")
                    // Bail out entirely on privilege violation — all subsequent calls will fail too
                    if osError.contains("-10004") || osError.contains("privilege violation") {
                        logger.error("Mail automation permission denied — skipping remaining body fetches")
                        return allEmails
                    }
                    continue
                }
                guard let output = stdout, !output.isEmpty else { continue }

                // Parse: first line is "recipients\tcc\treadStatus", rest is body
                let firstNewline = output.firstIndex(of: "\n") ?? output.endIndex
                let headerLine = String(output[output.startIndex..<firstNewline])
                let body = firstNewline < output.endIndex
                    ? String(output[output.index(after: firstNewline)...])
                    : ""

                let headerFields = headerLine.components(separatedBy: "\t")
                let recipients = headerFields.count > 0
                    ? headerFields[0].split(separator: ",").map { String($0) }
                    : []
                let cc = headerFields.count > 1
                    ? headerFields[1].split(separator: ",").map { String($0) }
                    : []
                let isRead = headerFields.count > 2 ? headerFields[2] == "true" : true

                let senderName = Self.extractName(from: meta.sender)
                let snippet = String(body.prefix(200))

                let dto = EmailDTO(
                    id: String(meta.mailID),
                    messageID: meta.messageID,
                    subject: meta.subject,
                    senderName: senderName,
                    senderEmail: meta.senderEmail,
                    recipientEmails: recipients,
                    ccEmails: cc,
                    date: meta.date,
                    bodyPlainText: body,
                    bodySnippet: snippet,
                    isRead: isRead,
                    folderName: mailbox == .sent ? "Sent" : "INBOX"
                )
                allEmails.append(dto)
            }
        }

        // Apply recipient filter
        if !filterRules.isEmpty {
            allEmails = allEmails.filter { email in
                let allRecipients = email.recipientEmails + email.ccEmails
                return filterRules.contains { $0.matches(recipientEmails: allRecipients) }
            }
            logger.debug("After recipient filtering: \(allEmails.count) emails")
        }

        logger.debug("Body fetch complete: \(allEmails.count) emails")
        return allEmails
    }

    /// Shared mailbox resolution AppleScript fragment (avoids duplication between body fetch and MIME fetch).
    private func mailboxResolutionScript(for mailbox: MailboxTarget) -> String {
        switch mailbox {
        case .inbox:
            return """
                    set mbx to missing value
                    try
                        set mbx to inbox of acct
                    end try
                    if mbx is missing value then
                        try
                            set mbx to mailbox "INBOX" of acct
                        end try
                    end if
                    if mbx is missing value then
                        try
                            set mbx to mailbox "Inbox" of acct
                        end try
                    end if
                    if mbx is missing value then
                        repeat with m in every mailbox of acct
                            try
                                set mName to name of m
                                if mName is "INBOX" or mName is "Inbox" or mName is "inbox" then
                                    set mbx to m
                                    exit repeat
                                end if
                            end try
                        end repeat
                    end if
                """
        case .sent:
            return """
                    set mbx to missing value
                    try
                        set mbx to mailbox "Sent Messages" of acct
                    end try
                    if mbx is missing value then
                        try
                            set mbx to mailbox "Sent" of acct
                        end try
                    end if
                    if mbx is missing value then
                        try
                            set mbx to mailbox "Sent Mail" of acct
                        end try
                    end if
                    if mbx is missing value then
                        try
                            set mbx to mailbox "[Gmail]/Sent Mail" of acct
                        end try
                    end if
                    if mbx is missing value then
                        repeat with m in every mailbox of acct
                            try
                                set mName to name of m
                                if mName contains "Sent" and mName does not contain "Junk" then
                                    set mbx to m
                                    exit repeat
                                end if
                            end try
                        end repeat
                    end if
                """
        }
    }

    // MARK: - Fetch MIME Source (for LinkedIn HTML parsing)

    /// Fetch the raw MIME source of a single message via AppleScript (`source of m`).
    ///
    /// Unlike `content of m` (plain text only), `source of m` returns the full RFC 2822
    /// MIME source, including the `text/html` part with all `<a href>` tags intact.
    /// Used by MailImportCoordinator to extract LinkedIn profile URLs from notification emails.
    ///
    /// - Returns: The raw MIME source string, or nil if the message cannot be located.
    func fetchMIMESource(for meta: MessageMeta) async -> String? {
        let escapedAcctName = meta.accountName.replacingOccurrences(of: "\"", with: "\\\"")
        let mbxResolution = mailboxResolutionScript(for: .inbox)
        let script = """
        tell application "Mail"
            with timeout of 30 seconds
                set acct to first account whose name is "\(escapedAcctName)"
                \(mbxResolution)
                if mbx is missing value then error "No inbox found"
                set m to (first message of mbx whose id is \(meta.mailID))
                return source of m
            end timeout
        end tell
        """

        let (stdout, osError) = await executeOsascript(script, timeout: 45)
        if let osError {
            logger.warning("MIME source fetch failed for message \(meta.mailID): \(osError, privacy: .public)")
            return nil
        }
        return stdout
    }

    /// Extract the decoded HTML body from a raw RFC 2822 MIME source string.
    ///
    /// Handles:
    /// - Single-part `Content-Type: text/html` messages
    /// - Multipart `Content-Type: multipart/alternative` (extracts the `text/html` part)
    /// - `Content-Transfer-Encoding: quoted-printable` decoding
    /// - `Content-Transfer-Encoding: base64` decoding
    ///
    /// - Returns: The decoded HTML string, or nil if no HTML part is found.
    static func extractHTMLFromMIMESource(_ source: String) -> String? {
        let lines = source.components(separatedBy: "\r\n").isEmpty
            ? source.components(separatedBy: "\n")
            : source.components(separatedBy: "\r\n")

        // Parse top-level headers to determine content type
        let topHeaders = parseHeaders(from: lines)
        let topContentType = topHeaders["content-type"] ?? ""

        if topContentType.lowercased().contains("text/html") {
            // Single-part HTML message — body starts after blank line
            return decodeBody(lines: lines, headers: topHeaders)
        }

        if topContentType.lowercased().contains("multipart") {
            // Extract boundary from Content-Type header
            // E.g.: Content-Type: multipart/alternative; boundary="----boundary123"
            guard let boundary = extractBoundary(from: topContentType) else { return nil }
            return extractHTMLPart(from: lines, boundary: boundary)
        }

        return nil
    }

    // MARK: - MIME Parsing Helpers

    /// Parse MIME headers from the beginning of a message (or part), up to the blank line separator.
    /// Returns a dictionary with lowercased header names as keys.
    private static func parseHeaders(from lines: [String]) -> [String: String] {
        var headers: [String: String] = [:]
        var currentName: String?
        var currentValue: String = ""

        for line in lines {
            if line.isEmpty { break }  // Blank line = end of headers

            // Folded header continuation (starts with whitespace)
            if let first = line.first, (first == " " || first == "\t"), let name = currentName {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
                headers[name] = currentValue
                continue
            }

            // New header: "Name: value"
            if let colonIdx = line.firstIndex(of: ":") {
                // Save previous header
                if let name = currentName {
                    headers[name] = currentValue
                }
                currentName = String(line[line.startIndex..<colonIdx]).lowercased()
                currentValue = String(line[line.index(after: colonIdx)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        // Save last header
        if let name = currentName {
            headers[name] = currentValue
        }
        return headers
    }

    /// Extract the `boundary` parameter from a Content-Type header value.
    /// E.g.: `multipart/alternative; boundary="abc123"` → `"abc123"`
    private static func extractBoundary(from contentType: String) -> String? {
        let pattern = #"boundary="?([^";]+)"?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(contentType.startIndex..., in: contentType)
        if let match = regex.firstMatch(in: contentType, range: range),
           let boundaryRange = Range(match.range(at: 1), in: contentType) {
            return String(contentType[boundaryRange]).trimmingCharacters(in: .init(charactersIn: "\""))
        }
        return nil
    }

    /// Extract and decode the `text/html` MIME part from a multipart message.
    private static func extractHTMLPart(from lines: [String], boundary: String) -> String? {
        let delimiter = "--" + boundary
        var inHTMLPart = false
        var partLines: [String] = []
        var partHeaders: [String: String] = [:]

        var i = 0
        while i < lines.count {
            let line = lines[i]

            // Boundary line: start of a new part
            if line.trimmingCharacters(in: .whitespaces) == delimiter
                || line.trimmingCharacters(in: .whitespaces) == delimiter + "--" {
                // If we were collecting an HTML part, we're done
                if inHTMLPart && !partLines.isEmpty {
                    return decodeBody(lines: partLines, headers: partHeaders)
                }
                inHTMLPart = false
                partLines = []
                partHeaders = [:]
                i += 1

                // Parse headers for this new part
                var partHeaderLines: [String] = []
                while i < lines.count && !lines[i].isEmpty {
                    partHeaderLines.append(lines[i])
                    i += 1
                }
                partHeaders = parseHeaders(from: partHeaderLines)
                let ct = partHeaders["content-type"] ?? ""
                inHTMLPart = ct.lowercased().contains("text/html")
                i += 1  // Skip the blank line separator
                continue
            }

            if inHTMLPart {
                partLines.append(line)
            }
            i += 1
        }

        // Handle case where HTML part extends to end of document
        if inHTMLPart && !partLines.isEmpty {
            return decodeBody(lines: partLines, headers: partHeaders)
        }
        return nil
    }

    /// Decode a MIME body using the Content-Transfer-Encoding from its headers.
    private static func decodeBody(lines: [String], headers: [String: String]) -> String? {
        // Find the blank line that separates headers from body
        let allLines = lines
        var bodyStartIndex = 0
        for (idx, line) in allLines.enumerated() {
            if line.isEmpty {
                bodyStartIndex = idx + 1
                break
            }
        }

        let bodyLines = Array(allLines[bodyStartIndex...])
        let encoding = (headers["content-transfer-encoding"] ?? "").lowercased()

        if encoding == "base64" {
            let joined = bodyLines.joined().replacingOccurrences(of: " ", with: "")
            if let data = Data(base64Encoded: joined, options: []),
               let decoded = String(data: data, encoding: .utf8) {
                return decoded
            }
            return nil
        }

        if encoding == "quoted-printable" {
            let raw = bodyLines.joined(separator: "\r\n")
            return decodeQuotedPrintable(raw)
        }

        // 7bit / 8bit / no encoding — return as-is
        return bodyLines.joined(separator: "\n")
    }

    /// Decode a quoted-printable encoded string.
    ///
    /// Rules:
    /// - `=XX` → the byte with hex value XX
    /// - `=\r\n` or `=\n` (soft line break) → removed (line continuation)
    private static func decodeQuotedPrintable(_ input: String) -> String {
        var result = ""
        var i = input.startIndex

        while i < input.endIndex {
            let c = input[i]
            if c == "=" {
                let next1 = input.index(after: i)
                guard next1 < input.endIndex else { break }

                // Soft line break: =\r\n or =\n
                if input[next1] == "\r" || input[next1] == "\n" {
                    // Skip the soft line break
                    i = input.index(after: next1)
                    if i < input.endIndex && input[i] == "\n" {
                        i = input.index(after: i)
                    }
                    continue
                }

                // Hex escape: =XX
                let next2 = input.index(after: next1)
                if next2 < input.endIndex {
                    let hex = String(input[next1...next2])
                    if let value = UInt8(hex, radix: 16) {
                        result.append(Character(UnicodeScalar(value)))
                        i = input.index(after: next2)
                        continue
                    }
                }
            }
            result.append(c)
            i = input.index(after: i)
        }
        return result
    }

    // MARK: - AppleScript Execution

    /// Execute AppleScript via NSAppleScript (used for small, fast queries like checkAccess).
    private func executeAppleScript(_ source: String) -> (NSAppleEventDescriptor?, String?) {
        var errorDict: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&errorDict)

        if let errorDict {
            let message = errorDict[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            return (nil, message)
        }
        return (result, nil)
    }

    /// Execute AppleScript via `/usr/bin/osascript` subprocess with a hard timeout.
    ///
    /// Advantages over `NSAppleScript`:
    /// - Hard kill timeout prevents infinite hangs (the Process is terminated)
    /// - Runs in a separate process, isolating SAM from Mail.app event loop issues
    /// - Returns plain text (stdout) which avoids NSAppleEventDescriptor memory accumulation
    /// - Does not block the actor's executor (uses `terminationHandler`)
    ///
    /// - Parameters:
    ///   - source: The AppleScript source code
    ///   - timeout: Maximum seconds to wait before killing the subprocess (default 30)
    /// - Returns: (stdout, errorMessage) — stdout is nil on failure
    private func executeOsascript(_ source: String, timeout: TimeInterval = 30) async -> (String?, String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Read pipes on background threads BEFORE waiting for process exit.
        // This prevents deadlock when stdout/stderr exceed the 64KB pipe buffer
        // (e.g. large email bodies). Without concurrent reading, the process blocks
        // on write, but we wait for exit before reading → deadlock.
        let stdoutBox = PipeReader(pipe: stdoutPipe)
        let stderrBox = PipeReader(pipe: stderrPipe)

        // Use a continuation so we don't block the actor's executor
        let terminationStatus: (Int32, Process.TerminationReason) = await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                continuation.resume(returning: (proc.terminationStatus, proc.terminationReason))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: (-1, .exit))
                return
            }

            // Hard timeout: kill the process if it exceeds the limit
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                if process.isRunning {
                    self?.logger.warning("osascript exceeded \(timeout)s timeout — terminating")
                    process.terminate()
                }
            }
        }

        // Wait for pipe readers to finish (they complete once the pipe closes after process exit)
        let stdoutData = await stdoutBox.result()
        let stderrData = await stderrBox.result()

        if terminationStatus.0 != 0 {
            let errStr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            if terminationStatus.1 == .uncaughtSignal {
                return (nil, "osascript timed out after \(Int(timeout))s")
            }
            if terminationStatus.0 == -1 {
                return (nil, "Failed to launch osascript")
            }
            return (nil, errStr)
        }

        let output = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (output, nil)
    }

    /// Reads from a Pipe on a GCD thread to prevent deadlock.
    /// Must be created before the process starts writing to the pipe.
    /// Uses GCD + async continuation (NOT Task.detached) because
    /// readDataToEndOfFile() is blocking I/O that must not run on
    /// the cooperative thread pool.
    private final class PipeReader: Sendable {
        private let _result: Task<Data, Never>

        init(pipe: Pipe) {
            let fileHandle = pipe.fileHandleForReading
            // Bridge blocking I/O to async via GCD
            _result = Task {
                await withUnsafeContinuation { cont in
                    DispatchQueue.global(qos: .utility).async {
                        let data = fileHandle.readDataToEndOfFile()
                        cont.resume(returning: data)
                    }
                }
            }
        }

        func result() async -> Data {
            await _result.value
        }
    }

    // MARK: - Parsing Helpers

    /// Extract email address from a sender string like "John Doe <john@example.com>"
    static func extractEmail(from sender: String) -> String {
        if let start = sender.lastIndex(of: "<"),
           let end = sender.lastIndex(of: ">"),
           start < end {
            return String(sender[sender.index(after: start)..<end])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
        }
        // Might already be a bare email address
        if sender.contains("@") {
            return sender.trimmingCharacters(in: .whitespaces).lowercased()
        }
        return sender.lowercased()
    }

    /// Extract display name from "Name <email>" format.
    static func extractName(from sender: String) -> String? {
        if let start = sender.lastIndex(of: "<") {
            let name = sender[sender.startIndex..<start]
                .trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// Detect mailing list and marketing emails from RFC 2822 headers without reading the body.
    ///
    /// Checks for the three most reliable indicators:
    /// - `List-Unsubscribe` (RFC 2369) — present on virtually all commercial mailing lists
    /// - `List-ID` (RFC 2919) — used by mailing list managers (Mailchimp, Constant Contact, etc.)
    /// - `Precedence: bulk` or `Precedence: list` — indicates bulk/automated sending
    ///
    /// These headers are fetched during the Phase 1 metadata sweep (no body required).
    static func isMarketingEmail(headers: String) -> Bool {
        guard !headers.isEmpty else { return false }
        let lower = headers.lowercased()
        if lower.contains("list-unsubscribe:") { return true }
        if lower.contains("list-id:") { return true }
        if lower.range(of: #"precedence:\s*(bulk|list)"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// Extract a list of strings from an NSAppleEventDescriptor list.
    static func extractStringList(from descriptor: NSAppleEventDescriptor?) -> [String] {
        guard let descriptor else { return [] }
        if descriptor.numberOfItems > 0 {
            var result: [String] = []
            for i in 1...descriptor.numberOfItems {
                if let s = descriptor.atIndex(i)?.stringValue {
                    result.append(s)
                }
            }
            return result
        }
        // Single value
        if let s = descriptor.stringValue, !s.isEmpty {
            return [s]
        }
        return []
    }
}
