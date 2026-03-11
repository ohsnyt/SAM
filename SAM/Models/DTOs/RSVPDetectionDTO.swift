//
//  RSVPDetectionDTO.swift
//  SAM
//
//  Created on March 11, 2026.
//  Sendable result from RSVP detection in message/email analysis.
//

import Foundation

/// Detected RSVP signal from a message or email.
/// Crosses actor boundary from analysis services → import coordinators → EventCoordinator.
struct RSVPDetectionDTO: Sendable, Identifiable {
    let id: UUID
    let responseText: String          // The actual text that triggered detection
    let detectedStatus: RSVPResponse  // What SAM thinks the response means
    let confidence: Double            // 0.0–1.0
    let senderName: String?           // Who sent the response
    let senderEmail: String?          // Email address if available

    // MARK: - Enhanced Detection Fields

    /// Additional guests the sender is bringing (e.g., "I'll bring 3 people from my team")
    let additionalGuestCount: Int

    /// Names of additional guests if mentioned (e.g., "I'll bring Mike and Lisa")
    let additionalGuestNames: [String]

    /// Event title or date reference detected in the message, for multi-event matching
    let eventReference: String?

    enum RSVPResponse: String, Sendable {
        case accepted       // "I'll be there", "Count me in"
        case declined       // "Can't make it", "I have a conflict"
        case tentative      // "Let me check", "I'll try"
        case question       // "Can I bring someone?", "What time?"
    }

    init(
        id: UUID = UUID(),
        responseText: String,
        detectedStatus: RSVPResponse,
        confidence: Double,
        senderName: String? = nil,
        senderEmail: String? = nil,
        additionalGuestCount: Int = 0,
        additionalGuestNames: [String] = [],
        eventReference: String? = nil
    ) {
        self.id = id
        self.responseText = responseText
        self.detectedStatus = detectedStatus
        self.confidence = confidence
        self.senderName = senderName
        self.senderEmail = senderEmail
        self.additionalGuestCount = additionalGuestCount
        self.additionalGuestNames = additionalGuestNames
        self.eventReference = eventReference
    }
}
