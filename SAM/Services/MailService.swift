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

            accounts.append(MailAccountDTO(
                id: name,
                name: name,
                emailAddresses: emails
            ))
        }

        logger.info("Found \(accounts.count) Mail.app accounts")
        return accounts
    }

    // MARK: - Fetch Emails

    /// Fetch recent emails from selected accounts' inboxes.
    func fetchEmails(
        accountIDs: [String],
        since: Date,
        filterRules: [MailFilterRule]
    ) async throws -> [EmailDTO] {
        guard !accountIDs.isEmpty else { return [] }

        let days = max(1, Calendar.current.dateComponents([.day], from: since, to: Date()).day ?? 30)
        var allEmails: [EmailDTO] = []

        for accountID in accountIDs {
            let escapedAccount = accountID.replacingOccurrences(of: "\"", with: "\\\"")

            // Phase 1: Bulk metadata sweep
            let metadataScript = """
            tell application "Mail"
                set acct to first account whose name is "\(escapedAccount)"
                set mbx to inbox of acct
                set cutoff to (current date) - (\(days) * days)
                set filteredMsgs to (every message of mbx whose date received > cutoff)
                if (count of filteredMsgs) is 0 then return {}
                set msgIDs to id of filteredMsgs
                set msgMessageIDs to message id of filteredMsgs
                set msgSubjects to subject of filteredMsgs
                set msgSenders to sender of filteredMsgs
                set msgDates to date received of filteredMsgs
                return {msgIDs, msgMessageIDs, msgSubjects, msgSenders, msgDates}
            end tell
            """

            let (metaResult, metaError) = executeAppleScript(metadataScript)
            if let metaError {
                logger.warning("Metadata sweep failed for \(accountID, privacy: .public): \(metaError, privacy: .public)")
                continue
            }
            guard let metaDesc = metaResult, metaDesc.numberOfItems >= 5 else { continue }

            guard let idsDesc = metaDesc.atIndex(1),
                  let messageIDsDesc = metaDesc.atIndex(2),
                  let subjectsDesc = metaDesc.atIndex(3),
                  let sendersDesc = metaDesc.atIndex(4),
                  let datesDesc = metaDesc.atIndex(5) else { continue }

            let count = idsDesc.numberOfItems
            if count == 0 { continue }

            logger.info("Account '\(accountID, privacy: .public)': \(count) messages in date range")

            // Parse metadata into lightweight structs for filtering
            struct MessageMeta {
                let mailID: Int32
                let messageID: String
                let subject: String
                let sender: String
                let senderEmail: String
                let date: Date
            }

            var metas: [MessageMeta] = []
            let dateFormatter = DateFormatter()
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")

            for i in 1...count {
                let mailID = idsDesc.atIndex(i)?.int32Value ?? 0
                let messageID = messageIDsDesc.atIndex(i)?.stringValue ?? ""
                let subject = subjectsDesc.atIndex(i)?.stringValue ?? "(No Subject)"
                let sender = sendersDesc.atIndex(i)?.stringValue ?? ""
                let dateVal = datesDesc.atIndex(i)?.dateValue ?? Date()

                // Extract email from sender string (e.g., "John Doe <john@example.com>")
                let senderEmail = Self.extractEmail(from: sender)

                metas.append(MessageMeta(
                    mailID: mailID,
                    messageID: messageID,
                    subject: subject,
                    sender: sender,
                    senderEmail: senderEmail,
                    date: dateVal
                ))
            }

            // Phase 2: Limit to maxBodyFetches (recipient filtering happens after Phase 3)
            let toFetch = Array(metas.prefix(maxBodyFetches))

            for meta in toFetch {
                let bodyScript = """
                tell application "Mail"
                    set acct to first account whose name is "\(escapedAccount)"
                    set mbx to inbox of acct
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

                // Extract sender name from "Name <email>" format
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

        // Apply recipient filter after Phase 3 (body + recipients are now available)
        if !filterRules.isEmpty {
            allEmails = allEmails.filter { email in
                filterRules.contains { $0.matches(recipientEmails: email.recipientEmails + email.ccEmails) }
            }
            logger.info("After recipient filtering: \(allEmails.count) emails")
        }

        logger.info("Total fetched: \(allEmails.count) emails from \(accountIDs.count) accounts")
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
