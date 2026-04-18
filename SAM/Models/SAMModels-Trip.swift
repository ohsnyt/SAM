//
//  SAMModels-Trip.swift
//  SAM_crm
//
//  Created by Assistant on 4/8/26.
//  Phase F1: iOS Companion App Foundation
//
//  Trip and mileage tracking models for field work.
//  Used by SAM Field (iOS) for GPS-based trip tracking
//  and by SAM (macOS) for mileage reports and tax summaries.
//

import SwiftData
import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - Trip
// ─────────────────────────────────────────────────────────────────────

/// A single trip (typically one day of driving between business stops).
///
/// Trips aggregate multiple `SamTripStop` records and compute total mileage.
/// Business miles are tax-deductible at the IRS standard mileage rate.
/// Trips can be planned (route planner) or recorded (GPS tracking).
@Model
public final class SamTrip {
    @Attribute(.unique) public var id: UUID

    /// Date of the trip (day-level granularity)
    public var date: Date

    /// Total distance driven in miles (computed from stop-to-stop routing)
    public var totalDistanceMiles: Double

    /// Business miles (sum of distances between business-tagged stops)
    public var businessDistanceMiles: Double

    /// Personal miles (totalDistanceMiles - businessDistanceMiles)
    public var personalDistanceMiles: Double

    /// Manual odometer readings (optional, for cross-validation)
    public var startOdometer: Double?
    public var endOdometer: Double?

    /// Trip lifecycle status
    public var statusRawValue: String = "recorded"

    @Transient
    public var status: TripStatus {
        get { TripStatus(rawValue: statusRawValue) ?? .recorded }
        set { statusRawValue = newValue.rawValue }
    }

    /// Optional user notes about the trip
    public var notes: String?

    /// When the trip started (first stop arrival or tracking start)
    public var startedAt: Date?

    /// When the trip ended (last stop departure or tracking stop)
    public var endedAt: Date?

    /// Reverse-geocoded address of the trip's starting point
    public var startAddress: String?

    /// Vehicle used (e.g. "Personal Vehicle", "Rental", or user-defined)
    public var vehicle: String = "Personal Vehicle"

    /// Trip-level business purpose (overrides per-stop derivation in exports)
    public var tripPurposeRawValue: String?

    @Transient
    public var tripPurpose: StopPurpose? {
        get { tripPurposeRawValue.flatMap { StopPurpose(rawValue: $0) } }
        set { tripPurposeRawValue = newValue?.rawValue }
    }

    /// Timestamp set when the user confirms the trip log is accurate
    public var confirmedAt: Date?

    /// Whether this trip was commuting (home↔regular office) — non-deductible, excluded from business miles totals
    public var isCommuting: Bool = false

    // ── Relationships ───────────────────────────────────────────────

    /// All stops on this trip, ordered by arrival time
    @Relationship(deleteRule: .cascade, inverse: \SamTripStop.trip)
    public var stops: [SamTripStop] = []

    // ── Computed ────────────────────────────────────────────────────

    /// Number of business stops
    @Transient
    public var businessStopCount: Int {
        stops.filter { $0.purpose != .personal }.count
    }

    public init(
        id: UUID = UUID(),
        date: Date = .now,
        totalDistanceMiles: Double = 0,
        businessDistanceMiles: Double = 0,
        personalDistanceMiles: Double = 0,
        status: TripStatus = .recorded,
        notes: String? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        startAddress: String? = nil,
        vehicle: String = "Personal Vehicle",
        tripPurpose: StopPurpose? = nil,
        confirmedAt: Date? = nil,
        isCommuting: Bool = false
    ) {
        self.id = id
        self.date = date
        self.totalDistanceMiles = totalDistanceMiles
        self.businessDistanceMiles = businessDistanceMiles
        self.personalDistanceMiles = personalDistanceMiles
        self.statusRawValue = status.rawValue
        self.notes = notes
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.startAddress = startAddress
        self.vehicle = vehicle
        self.tripPurposeRawValue = tripPurpose?.rawValue
        self.confirmedAt = confirmedAt
        self.isCommuting = isCommuting
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Trip Status
// ─────────────────────────────────────────────────────────────────────

public enum TripStatus: String, Codable, Sendable {
    /// Route planner created this trip but it hasn't started yet
    case planned
    /// Trip is actively being tracked (GPS recording)
    case tracking
    /// Trip has been completed and recorded
    case recorded
    /// Trip reviewed and confirmed by user
    case confirmed
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Trip Stop
// ─────────────────────────────────────────────────────────────────────

/// An individual stop on a trip — a location the user visited.
///
/// Stops are created automatically via GPS (arrival detection) or
/// manually by the user. Each stop captures location, purpose,
/// and visit outcome for business tracking.
@Model
public final class SamTripStop {
    @Attribute(.unique) public var id: UUID

    /// GPS coordinates of the stop
    public var latitude: Double
    public var longitude: Double

    /// Reverse-geocoded street address
    public var address: String?

    /// Business or location name (reverse-geocoded or user-entered)
    public var locationName: String?

    /// When the user arrived at this stop
    public var arrivedAt: Date

    /// When the user departed (nil if still at stop)
    public var departedAt: Date?

    /// Distance in miles from the previous stop (computed via MKDirections)
    public var distanceFromPreviousMiles: Double?

    /// Purpose of the visit
    public var purposeRawValue: String = "prospecting"

    @Transient
    public var purpose: StopPurpose {
        get { StopPurpose(rawValue: purposeRawValue) ?? .prospecting }
        set { purposeRawValue = newValue.rawValue }
    }

    /// What happened at this stop
    public var outcomeRawValue: String?

    @Transient
    public var outcome: VisitOutcome? {
        get { outcomeRawValue.flatMap { VisitOutcome(rawValue: $0) } }
        set { outcomeRawValue = newValue?.rawValue }
    }

    /// Quick notes about the stop (user-entered or voice debrief)
    public var notes: String?

    /// Order of this stop within the trip (for route planning)
    public var sortOrder: Int = 0

    // ── Relationships ───────────────────────────────────────────────

    /// The trip this stop belongs to
    @Relationship(deleteRule: .nullify)
    public var trip: SamTrip?

    /// Person associated with this stop (client visit, prospect meeting, etc.)
    @Relationship(deleteRule: .nullify)
    public var linkedPerson: SamPerson?

    /// Evidence item auto-created for this visit
    @Relationship(deleteRule: .nullify)
    public var linkedEvidence: SamEvidenceItem?

    public init(
        id: UUID = UUID(),
        latitude: Double,
        longitude: Double,
        address: String? = nil,
        locationName: String? = nil,
        arrivedAt: Date = .now,
        departedAt: Date? = nil,
        distanceFromPreviousMiles: Double? = nil,
        purpose: StopPurpose = .prospecting,
        outcome: VisitOutcome? = nil,
        notes: String? = nil,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
        self.locationName = locationName
        self.arrivedAt = arrivedAt
        self.departedAt = departedAt
        self.distanceFromPreviousMiles = distanceFromPreviousMiles
        self.purposeRawValue = purpose.rawValue
        self.outcomeRawValue = outcome?.rawValue
        self.notes = notes
        self.sortOrder = sortOrder
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Stop Purpose
// ─────────────────────────────────────────────────────────────────────

/// Why the user stopped at this location.
public enum StopPurpose: String, Codable, Sendable, CaseIterable {
    case clientMeeting = "ClientMeeting"
    case prospecting = "Prospecting"
    case recruiting = "Recruiting"
    case training = "Training"
    case admin = "Admin"
    case personal = "Personal"
    case other = "Other"

    public var displayName: String {
        switch self {
        case .clientMeeting: return "Client Meeting"
        case .prospecting:   return "Prospecting"
        case .recruiting:    return "Recruiting"
        case .training:      return "Training"
        case .admin:         return "Admin"
        case .personal:      return "Personal"
        case .other:         return "Other"
        }
    }

    public var iconName: String {
        switch self {
        case .clientMeeting: return "person.fill"
        case .prospecting:   return "building.2"
        case .recruiting:    return "person.badge.plus"
        case .training:      return "book.fill"
        case .admin:         return "folder.fill"
        case .personal:      return "house.fill"
        case .other:         return "mappin"
        }
    }

    /// Whether this purpose counts as business (tax-deductible)
    public var isBusiness: Bool {
        self != .personal
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Visit Outcome
// ─────────────────────────────────────────────────────────────────────

/// What happened at a business stop.
public enum VisitOutcome: String, Codable, Sendable, CaseIterable {
    case metDecisionMaker = "MetDecisionMaker"
    case leftCard = "LeftCard"
    case spokeWithStaff = "SpokeWithStaff"
    case notOpen = "NotOpen"
    case setAppointment = "SetAppointment"
    case noAnswer = "NoAnswer"
    case other = "Other"

    public var displayName: String {
        switch self {
        case .metDecisionMaker: return "Met Decision Maker"
        case .leftCard:         return "Left Card"
        case .spokeWithStaff:   return "Spoke with Staff"
        case .notOpen:          return "Not Open"
        case .setAppointment:   return "Set Appointment"
        case .noAnswer:         return "No Answer"
        case .other:            return "Other"
        }
    }

    public var iconName: String {
        switch self {
        case .metDecisionMaker: return "checkmark.circle.fill"
        case .leftCard:         return "rectangle.portrait.on.rectangle.portrait"
        case .spokeWithStaff:   return "person.2"
        case .notOpen:          return "lock.fill"
        case .setAppointment:   return "calendar.badge.plus"
        case .noAnswer:         return "door.left.hand.closed"
        case .other:            return "ellipsis.circle"
        }
    }

    /// Whether this outcome represents a positive contact
    public var isPositiveContact: Bool {
        switch self {
        case .metDecisionMaker, .spokeWithStaff, .setAppointment: return true
        default: return false
        }
    }
}
