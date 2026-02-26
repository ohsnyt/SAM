//
//  SAMModels-Compliance.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase Z: Compliance Awareness
//
//  Audit trail for AI-generated draft messages.
//

import Foundation
import SwiftData

@Model
final class ComplianceAuditEntry {

    @Attribute(.unique) var id: UUID

    /// Channel: "iMessage", "email", "content"
    var channelRawValue: String

    /// Recipient display name (if known).
    var recipientName: String?

    /// Recipient address (email or phone).
    var recipientAddress: String?

    /// The AI-generated draft text.
    var originalDraft: String

    /// The text that was actually sent (nil if not yet sent).
    var finalDraft: String?

    /// Whether the user modified the draft before sending.
    var wasModified: Bool

    /// JSON-encoded [ComplianceFlag], nil if no flags.
    var complianceFlagsJSON: String?

    /// Source outcome ID, if the draft was generated from an outcome.
    var outcomeID: UUID?

    /// When the audit entry was created.
    var createdAt: Date

    /// When the message was actually sent (nil if not yet sent).
    var sentAt: Date?

    init(
        channel: String,
        recipientName: String? = nil,
        recipientAddress: String? = nil,
        originalDraft: String,
        complianceFlagsJSON: String? = nil,
        outcomeID: UUID? = nil
    ) {
        self.id = UUID()
        self.channelRawValue = channel
        self.recipientName = recipientName
        self.recipientAddress = recipientAddress
        self.originalDraft = originalDraft
        self.finalDraft = nil
        self.wasModified = false
        self.complianceFlagsJSON = complianceFlagsJSON
        self.outcomeID = outcomeID
        self.createdAt = Date()
        self.sentAt = nil
    }
}
