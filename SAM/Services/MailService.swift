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
}

/// Actor-isolated service for reading email from Mail.app via NSAppleScript.
actor MailService {
    static let shared = MailService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "MailService")

    /// Maximum number of message bodies to fetch per import (bounds runtime).
    private let maxBodyFetches = 200

    private init() {}

    // MARK: - Access Check

    /// Check if Mail.app is available and we have automation permission.
    /// Returns nil on success, error message on failure.
    func checkAccess() async -> String? {
        let script = """
        tell application "Mail"
            return name of first account
        end tell
        """
        let (result, error) = executeAppleScript(script)
        if let error {
            if error.contains("-1743") || error.contains("not allowed") {
                return "SAM does not have permission to control Mail.app. Please grant access in System Settings → Privacy & Security → Automation."
            }
            if error.contains("-600") || error.contains("not running") || error.contains("isn't running") {
                return "Mail.app is not responding. Ensure Mail.app is running and that SAM has Automation access in System Settings → Privacy & Security → Automation."
            }
            return "Cannot access Mail.app: \(error)"
        }
        if result == nil {
            return "No Mail accounts found. Configure an account in Mail.app first."
        }
        return nil
    }

    // MARK: - Fetch Accounts

    /// Fetch available Mail.app accounts.
    func fetchAccounts() async -> [MailAccountDTO] {
        let script = """
        tell application "Mail"
            set acctNames to name of every account
            set acctEmails to email addresses of every account
            return {acctNames, acctEmails}
        end tell
        """
        let (result, error) = executeAppleScript(script)
        if let error {
            logger.error("Failed to fetch accounts: \(error, privacy: .public)")
            return []
        }
        guard let descriptor = result else { return [] }

        // Result is a list of two lists: {names, emailLists}
        guard descriptor.numberOfItems >= 2 else { return [] }

        let namesDesc = descriptor.atIndex(1)
        let emailsDesc = descriptor.atIndex(2)
        guard let namesDesc, let emailsDesc else { return [] }

        let count = namesDesc.numberOfItems
        var accounts: [MailAccountDTO] = []

        for i in 1...count {
            guard let nameDesc = namesDesc.atIndex(i),
                  let name = nameDesc.stringValue else { continue }

            var emails: [String] = []
            if let emailListDesc = emailsDesc.atIndex(i) {
                // Could be a single string or a list of strings
                if emailListDesc.numberOfItems > 0 {
                    for j in 1...emailListDesc.numberOfItems {
                        if let e = emailListDesc.atIndex(j)?.stringValue {
                            emails.append(e)
                        }
                    }
                } else if let single = emailListDesc.stringValue {
                    emails.append(single)
                }
            }

            // If no email addresses but name looks like an email, use it
            if emails.isEmpty && name.contains("@") {
                emails.append(name)
            }

            // Use first email as ID for lookups
            let accountID = emails.first ?? name
            accounts.append(MailAccountDTO(
                id: accountID,
                name: name,
                emailAddresses: emails
            ))
            logger.debug("Account: '\(name, privacy: .private)' emails=\(emails, privacy: .private)")
        }

        logger.info("Found \(accounts.count) Mail.app accounts")
        return accounts
    }

    // MARK: - Fetch Metadata (Phase 1 — fast)

    /// Phase 1: Fast metadata-only sweep of Mail.app inboxes.
    /// Returns (metas, warningMessage). Warning is non-nil if accounts had errors.
    func fetchMetadata(
        accountIDs: [String],
        since: Date
    ) async throws -> ([MessageMeta], String?) {
        guard !accountIDs.isEmpty else { return ([], nil) }

        let days = max(1, Calendar.current.dateComponents([.day], from: since, to: Date()).day ?? 30)
        var allMetas: [MessageMeta] = []
        var accountWarnings: [String] = []

        for accountID in accountIDs {
            let escapedEmail = accountID.replacingOccurrences(of: "\"", with: "\\\"")

            // Metadata sweep with per-message iteration (IMAP-safe)
            let metadataScript = """
            tell application "Mail"
                set targetEmail to "\(escapedEmail)"
                set cutoff to (current date) - (\(days) * days)
                set matchedName to ""
                set maxMsgs to \(maxBodyFetches)

                -- First pass: match by email addresses
                repeat with acct in every account
                    try
                        if (email addresses of acct) contains targetEmail then
                            set matchedName to name of acct
                            -- Resolve inbox: try property, by-name, then iterate
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
                            if mbx is missing value then
                                return {"__inbox_debug__", matchedName, "all inbox methods failed"}
                            end if
                            -- Fetch messages individually (IMAP-safe: no bulk property access)
                            set filteredMsgs to (every message of mbx whose date received > cutoff)
                            set msgCount to count of filteredMsgs
                            if msgCount is 0 then return {"__empty__", matchedName}
                            if msgCount > maxMsgs then set msgCount to maxMsgs
                            set msgIDs to {}
                            set msgMessageIDs to {}
                            set msgSubjects to {}
                            set msgSenders to {}
                            set msgDates to {}
                            set msgMarketing to {}
                            repeat with i from 1 to msgCount
                                try
                                    set msg to item i of filteredMsgs
                                    set theID to id of msg
                                    set theMsgID to message id of msg
                                    set theSubject to subject of msg
                                    set theSender to sender of msg
                                    set theDate to date received of msg
                                    set isMarketing to 0
                                    try
                                        content of header "List-Unsubscribe" of msg
                                        set isMarketing to 1
                                    end try
                                    if isMarketing is 0 then
                                        try
                                            content of header "List-ID" of msg
                                            set isMarketing to 1
                                        end try
                                    end if
                                    if isMarketing is 0 then
                                        try
                                            set p to content of header "Precedence" of msg
                                            if p contains "bulk" or p contains "list" then
                                                set isMarketing to 1
                                            end if
                                        end try
                                    end if
                                    set end of msgIDs to theID
                                    set end of msgMessageIDs to theMsgID
                                    set end of msgSubjects to theSubject
                                    set end of msgSenders to theSender
                                    set end of msgDates to theDate
                                    set end of msgMarketing to isMarketing
                                end try
                            end repeat
                            return {matchedName, msgIDs, msgMessageIDs, msgSubjects, msgSenders, msgDates, msgMarketing}
                        end if
                    end try
                end repeat

                -- Fallback: match by account name (some accounts store email as name)
                repeat with acct in every account
                    try
                        if (name of acct) is targetEmail then
                            set matchedName to name of acct
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
                            if mbx is missing value then
                                return {"__inbox_debug__", matchedName, "all inbox methods failed"}
                            end if
                            set filteredMsgs to (every message of mbx whose date received > cutoff)
                            set msgCount to count of filteredMsgs
                            if msgCount is 0 then return {"__empty__", matchedName}
                            if msgCount > maxMsgs then set msgCount to maxMsgs
                            set msgIDs to {}
                            set msgMessageIDs to {}
                            set msgSubjects to {}
                            set msgSenders to {}
                            set msgDates to {}
                            set msgMarketing to {}
                            repeat with i from 1 to msgCount
                                try
                                    set msg to item i of filteredMsgs
                                    set theID to id of msg
                                    set theMsgID to message id of msg
                                    set theSubject to subject of msg
                                    set theSender to sender of msg
                                    set theDate to date received of msg
                                    set isMarketing to 0
                                    try
                                        content of header "List-Unsubscribe" of msg
                                        set isMarketing to 1
                                    end try
                                    if isMarketing is 0 then
                                        try
                                            content of header "List-ID" of msg
                                            set isMarketing to 1
                                        end try
                                    end if
                                    if isMarketing is 0 then
                                        try
                                            set p to content of header "Precedence" of msg
                                            if p contains "bulk" or p contains "list" then
                                                set isMarketing to 1
                                            end if
                                        end try
                                    end if
                                    set end of msgIDs to theID
                                    set end of msgMessageIDs to theMsgID
                                    set end of msgSubjects to theSubject
                                    set end of msgSenders to theSender
                                    set end of msgDates to theDate
                                    set end of msgMarketing to isMarketing
                                end try
                            end repeat
                            return {matchedName, msgIDs, msgMessageIDs, msgSubjects, msgSenders, msgDates, msgMarketing}
                        end if
                    end try
                end repeat
                return {"__not_found__"}
            end tell
            """

            let (metaResult, metaError) = executeAppleScript(metadataScript)
            if let metaError {
                logger.warning("Metadata sweep failed for \(accountID, privacy: .private): \(metaError, privacy: .public)")
                accountWarnings.append("'\(accountID)': \(metaError)")
                continue
            }
            guard let metaDesc = metaResult else { continue }

            // Check for sentinel values (status reports, not data)
            let firstItem = metaDesc.atIndex(1)?.stringValue ?? ""
            if firstItem.hasPrefix("__") {
                let acctName = metaDesc.atIndex(2)?.stringValue ?? "?"
                switch firstItem {
                case "__not_found__":
                    logger.warning("No account found with email \(accountID, privacy: .private)")
                    accountWarnings.append("No Mail account found for '\(accountID)'")
                case "__inbox_debug__":
                    let errDetail = metaDesc.atIndex(3)?.stringValue ?? "unknown"
                    logger.error("Account '\(acctName, privacy: .private)' matched but inbox not accessible. Errors: \(errDetail, privacy: .public)")
                    accountWarnings.append("Account '\(acctName)' inbox not accessible: \(errDetail)")
                case "__fetch_debug__":
                    let errDetail = metaDesc.atIndex(3)?.stringValue ?? "unknown"
                    logger.error("Account '\(acctName, privacy: .private)' inbox found but message fetch failed: \(errDetail, privacy: .public)")
                    accountWarnings.append("Account '\(acctName)' message fetch failed: \(errDetail)")
                case "__empty__":
                    logger.info("Account '\(acctName, privacy: .private)' matched, no messages in date range")
                default:
                    logger.warning("Unknown sentinel '\(firstItem, privacy: .public)' for \(accountID, privacy: .private)")
                }
                continue
            }

            guard metaDesc.numberOfItems >= 6,
                  let acctNameDesc = metaDesc.atIndex(1),
                  let idsDesc = metaDesc.atIndex(2),
                  let messageIDsDesc = metaDesc.atIndex(3),
                  let subjectsDesc = metaDesc.atIndex(4),
                  let sendersDesc = metaDesc.atIndex(5),
                  let datesDesc = metaDesc.atIndex(6) else { continue }

            // Index 7 is marketing flags (0/1 integers) — optional for forward compatibility
            let marketingDesc = metaDesc.atIndex(7)

            let resolvedAccountName = acctNameDesc.stringValue ?? accountID
            let count = idsDesc.numberOfItems
            if count == 0 { continue }

            logger.info("Account '\(resolvedAccountName, privacy: .private)' (email: \(accountID, privacy: .private)): \(count) messages in date range")

            for i in 1...count {
                let mailID = idsDesc.atIndex(i)?.int32Value ?? 0
                let messageID = messageIDsDesc.atIndex(i)?.stringValue ?? ""
                let subject = subjectsDesc.atIndex(i)?.stringValue ?? "(No Subject)"
                let sender = sendersDesc.atIndex(i)?.stringValue ?? ""
                let dateVal = datesDesc.atIndex(i)?.dateValue ?? Date()
                let senderEmail = Self.extractEmail(from: sender)
                let isLikelyMarketing = (marketingDesc?.atIndex(i)?.int32Value ?? 0) != 0

                allMetas.append(MessageMeta(
                    mailID: mailID,
                    messageID: messageID,
                    subject: subject,
                    sender: sender,
                    senderEmail: senderEmail,
                    date: dateVal,
                    accountName: resolvedAccountName,
                    isLikelyMarketing: isLikelyMarketing
                ))
            }
        }

        logger.info("Metadata sweep complete: \(allMetas.count) messages from \(accountIDs.count) accounts")
        let warning = accountWarnings.isEmpty ? nil : accountWarnings.joined(separator: "\n")
        return (allMetas, warning)
    }

    // MARK: - Fetch Bodies (Phase 2 — slow)

    /// Phase 2: Fetch message bodies + recipients for a given subset of MessageMetas.
    /// Apply filter rules after body/recipient data is available.
    func fetchBodies(
        for metas: [MessageMeta],
        filterRules: [MailFilterRule]
    ) async -> [EmailDTO] {
        guard !metas.isEmpty else { return [] }

        var allEmails: [EmailDTO] = []

        // Group metas by account to minimize AppleScript overhead
        let byAccount = Dictionary(grouping: metas, by: \.accountName)

        for (accountName, accountMetas) in byAccount {
            let escapedAcctName = accountName.replacingOccurrences(of: "\"", with: "\\\"")
            let toFetch = Array(accountMetas.prefix(maxBodyFetches))

            for meta in toFetch {
                let bodyScript = """
                tell application "Mail"
                    set acct to first account whose name is "\(escapedAcctName)"
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
                    if mbx is missing value then error "No inbox found"
                    set m to (first message of mbx whose id is \(meta.mailID))
                    set msgContent to content of m
                    set msgRecipients to address of every to recipient of m
                    set msgCC to address of every cc recipient of m
                    set msgRead to read status of m
                    return {msgContent, msgRecipients, msgCC, msgRead}
                end tell
                """

                let (bodyResult, bodyError) = executeAppleScript(bodyScript)
                if let bodyError {
                    logger.warning("Body fetch failed for message \(meta.mailID): \(bodyError, privacy: .public)")
                    continue
                }
                guard let bodyDesc = bodyResult, bodyDesc.numberOfItems >= 4 else { continue }

                let body = bodyDesc.atIndex(1)?.stringValue ?? ""
                let recipients = Self.extractStringList(from: bodyDesc.atIndex(2))
                let cc = Self.extractStringList(from: bodyDesc.atIndex(3))
                let isRead = bodyDesc.atIndex(4)?.booleanValue ?? true

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
                    folderName: "INBOX"
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
            logger.info("After recipient filtering: \(allEmails.count) emails")
        }

        logger.info("Body fetch complete: \(allEmails.count) emails")
        return allEmails
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
        let script = """
        tell application "Mail"
            set acct to first account whose name is "\(escapedAcctName)"
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
            if mbx is missing value then error "No inbox found"
            set m to (first message of mbx whose id is \(meta.mailID))
            return source of m
        end tell
        """

        let (result, error) = executeAppleScript(script)
        if let error {
            logger.warning("MIME source fetch failed for message \(meta.mailID): \(error, privacy: .public)")
            return nil
        }
        return result?.stringValue
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
