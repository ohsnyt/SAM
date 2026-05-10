//
//  GraphLens.swift
//  SAM
//
//  The four lenses that drive the relationship graph experience.
//  Each lens is a focused view of the network that builds progressively,
//  starting from Me at center and expanding in waves.
//

import SwiftUI

enum GraphLens: String, CaseIterable, Identifiable, Sendable {
    case bookOfBusiness
    case referrerProductivity
    case missedNudges
    case familyGaps
    case allContacts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bookOfBusiness:       return "Book of Business"
        case .referrerProductivity: return "Referrer Productivity"
        case .missedNudges:         return "Missed Nudges"
        case .familyGaps:           return "Family Gaps"
        case .allContacts:          return "All Contacts"
        }
    }

    /// Question the lens answers — surfaced on the picker card.
    var subtitle: String {
        switch self {
        case .bookOfBusiness:       return "Where did my book come from?"
        case .referrerProductivity: return "Who drives my growth?"
        case .missedNudges:         return "Where did I lose momentum?"
        case .familyGaps:           return "Who am I missing the family picture on?"
        case .allContacts:          return "Show me everything — let me filter."
        }
    }

    /// Longer description for the picker card.
    var description: String {
        switch self {
        case .bookOfBusiness:
            return "Active clients with their family ties and the people who introduced them. Singletons stand out as gaps to fill."
        case .referrerProductivity:
            return "Top referrers ranked by clients introduced. Click a referrer to see what makes them productive."
        case .missedNudges:
            return "People SAM nudged you about — clustered by why momentum slipped. Each has a path to recover."
        case .familyGaps:
            return "Active clients with no defined family. Each card shows what's missing and how to enrich."
        case .allContacts:
            return "Everyone SAM knows about, with every connection it can see. Use the toolbar's role and connection filters to drill into church, ABT, prospects, or any group you've defined."
        }
    }

    var systemImage: String {
        switch self {
        case .bookOfBusiness:       return "person.3.sequence"
        case .referrerProductivity: return "chart.line.uptrend.xyaxis"
        case .missedNudges:         return "bell.slash"
        case .familyGaps:           return "person.2.badge.plus"
        case .allContacts:          return "circle.grid.3x3.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .bookOfBusiness:       return .green
        case .referrerProductivity: return .yellow
        case .missedNudges:         return .orange
        case .familyGaps:           return .blue
        case .allContacts:          return .purple
        }
    }
}

/// Stage of progressive reveal during a lens load.
enum LensLoadingPhase: Equatable, Sendable {
    case idle
    case anchoring          // Placing Me + first visible nodes
    case primary            // First wave streaming in (e.g. clients)
    case secondary          // Second wave (e.g. family)
    case tertiary           // Third wave (e.g. referrers)
    case complete

    var progressLabel: String {
        switch self {
        case .idle:       return ""
        case .anchoring:  return "Setting the stage…"
        case .primary:    return "Bringing in your people…"
        case .secondary:  return "Drawing connections…"
        case .tertiary:   return "Tracing the chain back…"
        case .complete:   return ""
        }
    }
}
