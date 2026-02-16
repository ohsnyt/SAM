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
    let sender: String        // raw "Name <email>"
    let senderEmail: String   // extracted, lowercased
    let date: Date
    let accountName: String   // resolved account name for body fetch
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
            logger.debug("Account: '\(name, privacy: .public)' emails=\(emails, privacy: .public)")
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
                            repeat with i from 1 to msgCount
                                try
                                    set msg to item i of filteredMsgs
                                    set end of msgIDs to id of msg
                                    set end of msgMessageIDs to message id of msg
                                    set end of msgSubjects to subject of msg
                                    set end of msgSenders to sender of msg
                                    set end of msgDates to date received of msg
                                end try
                            end repeat
                            return {matchedName, msgIDs, msgMessageIDs, msgSubjects, msgSenders, msgDates}
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
                            repeat with i from 1 to msgCount
                                try
                                    set msg to item i of filteredMsgs
                                    set end of msgIDs to id of msg
                                    set end of msgMessageIDs to message id of msg
                                    set end of msgSubjects to subject of msg
                                    set end of msgSenders to sender of msg
                                    set end of msgDates to date received of msg
                                end try
                            end repeat
                            return {matchedName, msgIDs, msgMessageIDs, msgSubjects, msgSenders, msgDates}
                        end if
                    end try
                end repeat
                return {"__not_found__"}
            end tell
            """

            let (metaResult, metaError) = executeAppleScript(metadataScript)
            if let metaError {
                logger.warning("Metadata sweep failed for \(accountID, privacy: .public): \(metaError, privacy: .public)")
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
                    logger.warning("No account found with email \(accountID, privacy: .public)")
                    accountWarnings.append("No Mail account found for '\(accountID)'")
                case "__inbox_debug__":
                    let errDetail = metaDesc.atIndex(3)?.stringValue ?? "unknown"
                    logger.error("Account '\(acctName, privacy: .public)' matched but inbox not accessible. Errors: \(errDetail, privacy: .public)")
                    accountWarnings.append("Account '\(acctName)' inbox not accessible: \(errDetail)")
                case "__fetch_debug__":
                    let errDetail = metaDesc.atIndex(3)?.stringValue ?? "unknown"
                    logger.error("Account '\(acctName, privacy: .public)' inbox found but message fetch failed: \(errDetail, privacy: .public)")
                    accountWarnings.append("Account '\(acctName)' message fetch failed: \(errDetail)")
                case "__empty__":
                    logger.info("Account '\(acctName, privacy: .public)' matched, no messages in date range")
                default:
                    logger.warning("Unknown sentinel '\(firstItem, privacy: .public)' for \(accountID, privacy: .public)")
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

            let resolvedAccountName = acctNameDesc.stringValue ?? accountID
            let count = idsDesc.numberOfItems
            if count == 0 { continue }

            logger.info("Account '\(resolvedAccountName, privacy: .public)' (email: \(accountID, privacy: .public)): \(count) messages in date range")

            for i in 1...count {
                let mailID = idsDesc.atIndex(i)?.int32Value ?? 0
                let messageID = messageIDsDesc.atIndex(i)?.stringValue ?? ""
                let subject = subjectsDesc.atIndex(i)?.stringValue ?? "(No Subject)"
                let sender = sendersDesc.atIndex(i)?.stringValue ?? ""
                let dateVal = datesDesc.atIndex(i)?.dateValue ?? Date()
                let senderEmail = Self.extractEmail(from: sender)

                allMetas.append(MessageMeta(
                    mailID: mailID,
                    messageID: messageID,
                    subject: subject,
                    sender: sender,
                    senderEmail: senderEmail,
                    date: dateVal,
                    accountName: resolvedAccountName
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
