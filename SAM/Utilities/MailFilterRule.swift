//
//  MailFilterRule.swift
//  SAM_crm
//
//  Created by Assistant on 2/13/26.
//  Email Integration - Recipient filtering
//
//  Rules for filtering emails by recipient address.
//

import Foundation

/// A rule for filtering emails by recipient address.
/// Stored in UserDefaults as JSON.
struct MailFilterRule: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    let value: String  // recipient email address, e.g. "work@example.com"

    nonisolated func matches(recipientEmails: [String]) -> Bool {
        let canonical = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return recipientEmails.contains { $0.lowercased() == canonical }
    }
}
