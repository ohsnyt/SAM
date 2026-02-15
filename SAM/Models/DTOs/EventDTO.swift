//
//  EventDTO.swift
//  SAM_crm
//
//  Created on February 10, 2026.
//  Phase E: Calendar & Evidence
//
//  Sendable Data Transfer Object for EKEvent.
//  Safely crosses actor boundaries (EKEvent cannot).
//

import Foundation
import EventKit

/// Sendable wrapper for EKEvent that can cross actor boundaries.
/// Never pass EKEvent directly between actors - always use EventDTO.
struct EventDTO: Sendable {
    
    // MARK: - Core Properties
    
    /// Stable identifier from EKEvent.eventIdentifier
    let identifier: String
    
    /// Calendar identifier this event belongs to
    let calendarIdentifier: String
    
    /// Event title
    let title: String
    
    /// Event location (if any)
    let location: String?
    
    /// Event notes/description
    let notes: String?
    
    /// Start date/time
    let startDate: Date
    
    /// End date/time
    let endDate: Date
    
    /// True if this is an all-day event
    let isAllDay: Bool
    
    /// Event status (confirmed, tentative, canceled)
    let status: EventStatus
    
    /// Event availability (busy, free, tentative, unavailable)
    let availability: EventAvailability
    
    // MARK: - Attendees
    
    /// List of attendees (participants)
    let attendees: [AttendeeDTO]
    
    // MARK: - Organizer
    
    /// Event organizer (if any)
    let organizer: AttendeeDTO?
    
    // MARK: - Recurrence
    
    /// True if this is a recurring event
    let hasRecurrenceRules: Bool
    
    /// True if this is a detached occurrence of a recurring event
    let isDetached: Bool
    
    // MARK: - Metadata
    
    /// Creation date
    let creationDate: Date?
    
    /// Last modification date
    let lastModifiedDate: Date?
    
    /// URL associated with event
    let url: URL?
    
    // MARK: - Nested Types
    
    enum EventStatus: String, Sendable {
        case none
        case confirmed
        case tentative
        case canceled
    }
    
    enum EventAvailability: String, Sendable {
        case notSupported
        case busy
        case free
        case tentative
        case unavailable
    }
    
    struct AttendeeDTO: Sendable {
        let name: String?
        let emailAddress: String?
        let participantStatus: ParticipantStatus
        let participantRole: ParticipantRole
        let participantType: ParticipantType
        let isCurrentUser: Bool
        
        enum ParticipantStatus: String, Sendable {
            case unknown
            case pending
            case accepted
            case declined
            case tentative
            case delegated
            case completed
            case inProcess
        }
        
        enum ParticipantRole: String, Sendable {
            case unknown
            case required
            case optional
            case chair
            case nonParticipant
        }
        
        enum ParticipantType: String, Sendable {
            case unknown
            case person
            case room
            case resource
            case group
        }
    }
    
    // MARK: - Memberwise Initializer

    /// Direct memberwise init for constructing EventDTO without an EKEvent (used by tests).
    init(
        identifier: String,
        calendarIdentifier: String,
        title: String,
        location: String?,
        notes: String?,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        status: EventStatus,
        availability: EventAvailability,
        attendees: [AttendeeDTO],
        organizer: AttendeeDTO?,
        hasRecurrenceRules: Bool,
        isDetached: Bool,
        creationDate: Date?,
        lastModifiedDate: Date?,
        url: URL?
    ) {
        self.identifier = identifier
        self.calendarIdentifier = calendarIdentifier
        self.title = title
        self.location = location
        self.notes = notes
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.status = status
        self.availability = availability
        self.attendees = attendees
        self.organizer = organizer
        self.hasRecurrenceRules = hasRecurrenceRules
        self.isDetached = isDetached
        self.creationDate = creationDate
        self.lastModifiedDate = lastModifiedDate
        self.url = url
    }

    // MARK: - Initialization from EKEvent

    nonisolated init(from event: EKEvent) {
        self.identifier = event.eventIdentifier
        self.calendarIdentifier = event.calendar?.calendarIdentifier ?? ""
        self.title = event.title ?? "Untitled Event"
        self.location = event.location
        self.notes = event.notes
        self.startDate = event.startDate
        self.endDate = event.endDate
        self.isAllDay = event.isAllDay
        
        // Map status
        switch event.status {
        case .none:
            self.status = .none
        case .confirmed:
            self.status = .confirmed
        case .tentative:
            self.status = .tentative
        case .canceled:
            self.status = .canceled
        @unknown default:
            self.status = .none
        }
        
        // Map availability
        switch event.availability {
        case .notSupported:
            self.availability = .notSupported
        case .busy:
            self.availability = .busy
        case .free:
            self.availability = .free
        case .tentative:
            self.availability = .tentative
        case .unavailable:
            self.availability = .unavailable
        @unknown default:
            self.availability = .notSupported
        }
        
        // Map attendees
        self.attendees = (event.attendees ?? []).map { participant in
            // Extract email from URL (format: "mailto:email@example.com")
            let emailAddress = participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            
            return AttendeeDTO(
                name: participant.name,
                emailAddress: emailAddress.isEmpty ? nil : emailAddress,
                participantStatus: Self.mapParticipantStatus(participant.participantStatus),
                participantRole: Self.mapParticipantRole(participant.participantRole),
                participantType: Self.mapParticipantType(participant.participantType),
                isCurrentUser: participant.isCurrentUser
            )
        }
        
        // Map organizer
        if let organizer = event.organizer {
            // Extract email from URL (format: "mailto:email@example.com")
            let emailAddress = organizer.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            
            self.organizer = AttendeeDTO(
                name: organizer.name,
                emailAddress: emailAddress.isEmpty ? nil : emailAddress,
                participantStatus: Self.mapParticipantStatus(organizer.participantStatus),
                participantRole: Self.mapParticipantRole(organizer.participantRole),
                participantType: Self.mapParticipantType(organizer.participantType),
                isCurrentUser: organizer.isCurrentUser
            )
        } else {
            self.organizer = nil
        }
        
        // Recurrence
        self.hasRecurrenceRules = event.hasRecurrenceRules
        self.isDetached = event.isDetached
        
        // Metadata
        self.creationDate = event.creationDate
        self.lastModifiedDate = event.lastModifiedDate
        self.url = event.url
    }
    
    // MARK: - Helper Mapping Functions
    
    private nonisolated static func mapParticipantStatus(_ status: EKParticipantStatus) -> AttendeeDTO.ParticipantStatus {
        switch status {
        case .unknown:
            return .unknown
        case .pending:
            return .pending
        case .accepted:
            return .accepted
        case .declined:
            return .declined
        case .tentative:
            return .tentative
        case .delegated:
            return .delegated
        case .completed:
            return .completed
        case .inProcess:
            return .inProcess
        @unknown default:
            return .unknown
        }
    }
    
    private nonisolated static func mapParticipantRole(_ role: EKParticipantRole) -> AttendeeDTO.ParticipantRole {
        switch role {
        case .unknown:
            return .unknown
        case .required:
            return .required
        case .optional:
            return .optional
        case .chair:
            return .chair
        case .nonParticipant:
            return .nonParticipant
        @unknown default:
            return .unknown
        }
    }
    
    private nonisolated static func mapParticipantType(_ type: EKParticipantType) -> AttendeeDTO.ParticipantType {
        switch type {
        case .unknown:
            return .unknown
        case .person:
            return .person
        case .room:
            return .room
        case .resource:
            return .resource
        case .group:
            return .group
        @unknown default:
            return .unknown
        }
    }
}

// MARK: - Helper Extensions

extension EventDTO {
    
    /// Generate a snippet for display (first 100 characters of notes or location)
    var snippet: String {
        if let notes = notes, !notes.isEmpty {
            return String(notes.prefix(100))
        } else if let location = location, !location.isEmpty {
            return location
        } else {
            return "No additional details"
        }
    }
    
    /// Get all participant email addresses (useful for linking to SamPerson)
    var participantEmails: [String] {
        attendees.compactMap { $0.emailAddress }
    }
    
    /// Get all participant names
    var participantNames: [String] {
        attendees.compactMap { $0.name }
    }
    
    /// True if user is organizer
    var isUserOrganizer: Bool {
        organizer?.isCurrentUser ?? false
    }
    
    /// True if user is attending
    var isUserAttending: Bool {
        attendees.contains { $0.isCurrentUser }
    }
    
    /// Duration in seconds
    var duration: TimeInterval {
        endDate.timeIntervalSince(startDate)
    }
    
    /// Format for sourceUID in SamEvidenceItem
    var sourceUID: String {
        "eventkit:\(identifier)"
    }
}
