//
//  SAMModels-Production.swift
//  SAM
//
//  Created on February 25, 2026.
//  Phase S: Production Tracking
//
//  Tracks individual production records (policies written, submitted,
//  approved, issued) per person with product type and carrier info.
//

import SwiftData
import Foundation
import SwiftUI

// MARK: - WFGProductType

/// Product types available through World Financial Group.
public enum WFGProductType: String, Codable, Sendable, CaseIterable {
    case iul            = "IUL"
    case termLife       = "Term Life"
    case wholeLife      = "Whole Life"
    case annuity        = "Annuity"
    case retirementPlan = "Retirement Plan"
    case educationPlan  = "Education Plan"
    case other          = "Other"

    public var displayName: String { rawValue }

    public var icon: String {
        switch self {
        case .iul:            return "shield.checkered"
        case .termLife:       return "clock.badge.checkmark"
        case .wholeLife:      return "shield.fill"
        case .annuity:        return "banknote"
        case .retirementPlan: return "figure.walk"
        case .educationPlan:  return "graduationcap"
        case .other:          return "doc.text"
        }
    }

    public var color: Color {
        switch self {
        case .iul:            return .blue
        case .termLife:       return .teal
        case .wholeLife:      return .indigo
        case .annuity:        return .green
        case .retirementPlan: return .orange
        case .educationPlan:  return .purple
        case .other:          return .gray
        }
    }
}

// MARK: - ProductionStatus

/// Lifecycle status of a production record.
public enum ProductionStatus: String, Codable, Sendable, CaseIterable {
    case submitted = "Submitted"
    case approved  = "Approved"
    case declined  = "Declined"
    case issued    = "Issued"

    public var displayName: String { rawValue }

    public var icon: String {
        switch self {
        case .submitted: return "paperplane"
        case .approved:  return "checkmark.circle"
        case .declined:  return "xmark.circle"
        case .issued:    return "checkmark.seal.fill"
        }
    }

    public var color: Color {
        switch self {
        case .submitted: return .orange
        case .approved:  return .blue
        case .declined:  return .red
        case .issued:    return .green
        }
    }

    /// Next status in the happy-path progression, or nil at terminal states.
    public var next: ProductionStatus? {
        switch self {
        case .submitted: return .approved
        case .approved:  return .issued
        case .declined:  return nil
        case .issued:    return nil
        }
    }
}

// MARK: - ProductionRecord

/// A single production record representing a policy or product sold.
/// Linked to a SamPerson (Client/Applicant). Uses nullify so production
/// history survives person deletion.
@Model
public final class ProductionRecord {
    @Attribute(.unique) public var id: UUID

    /// The person this production belongs to. Nil if person was deleted.
    @Relationship(deleteRule: .nullify)
    public var person: SamPerson?

    /// Raw storage for WFGProductType enum.
    public var productTypeRawValue: String

    /// Raw storage for ProductionStatus enum.
    public var statusRawValue: String

    /// Insurance carrier (e.g., "Transamerica", "Nationwide").
    public var carrierName: String

    /// Annual premium amount.
    public var annualPremium: Double

    /// When the application was submitted.
    public var submittedDate: Date

    /// When approved/declined/issued (nil while pending).
    public var resolvedDate: Date?

    /// Optional policy number once issued.
    public var policyNumber: String?

    /// Free-form notes about this production record.
    public var notes: String?

    public var createdAt: Date
    public var updatedAt: Date

    // MARK: - Transient Typed Accessors

    @Transient
    public var productType: WFGProductType {
        get { WFGProductType(rawValue: productTypeRawValue) ?? .other }
        set { productTypeRawValue = newValue.rawValue }
    }

    @Transient
    public var status: ProductionStatus {
        get { ProductionStatus(rawValue: statusRawValue) ?? .submitted }
        set { statusRawValue = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        person: SamPerson?,
        productType: WFGProductType,
        status: ProductionStatus = .submitted,
        carrierName: String,
        annualPremium: Double,
        submittedDate: Date = .now,
        resolvedDate: Date? = nil,
        policyNumber: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.person = person
        self.productTypeRawValue = productType.rawValue
        self.statusRawValue = status.rawValue
        self.carrierName = carrierName
        self.annualPremium = annualPremium
        self.submittedDate = submittedDate
        self.resolvedDate = resolvedDate
        self.policyNumber = policyNumber
        self.notes = notes
        self.createdAt = .now
        self.updatedAt = .now
    }
}
