//
//  EmailDTO.swift
//  SAM_crm
//
//  Created by Assistant on 2/13/26.
//  Email Integration - Data Transfer Object
//
//  Sendable wrapper for an IMAP email message.
//

import Foundation

/// Sendable wrapper for an IMAP email message.
/// Crosses actor boundaries from MailService → MailImportCoordinator.
struct EmailDTO: Sendable, Identifiable {
    let id: String             // IMAP message UID or Message-ID header
    let messageID: String      // RFC 2822 Message-ID (globally unique)
    let subject: String
    let senderName: String?
    let senderEmail: String
    let recipientEmails: [String]
    let ccEmails: [String]
    let bccEmails: [String]
    let date: Date
    let bodyPlainText: String  // Plain text body (stripped HTML if needed)
    let bodySnippet: String    // First ~200 chars for display
    let isRead: Bool
    let folderName: String     // e.g. "INBOX"

    /// Format for sourceUID in SamEvidenceItem
    var sourceUID: String {
        "mail:\(messageID)"
    }

    /// All participant email addresses (sender + recipients + CC + BCC)
    var allParticipantEmails: [String] {
        [senderEmail] + recipientEmails + ccEmails + bccEmails
    }

    /// True when the ingestion path tagged this email as outbound.
    /// Hint only — authoritative truth lives on `SamEvidenceItem.direction`. The ingestion
    /// pipeline sets `folderName` to `"Sent"` exactly when it determined the message is
    /// outbound (by sender-address match, not folder-name heuristic), so we match strictly.
    var isOutbound: Bool {
        folderName.caseInsensitiveCompare("Sent") == .orderedSame
    }
}
