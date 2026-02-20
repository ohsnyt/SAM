//
//  RelationshipSummaryDTO.swift
//  SAM
//
//  Phase L-2: AI-generated relationship summary DTO
//

import Foundation

/// Sendable wrapper for an AI-generated relationship summary.
/// Crosses actor boundary from NoteAnalysisService → NoteAnalysisCoordinator.
struct RelationshipSummaryDTO: Sendable {
    /// 2-3 sentence relationship overview focused on what matters for the next interaction
    let overview: String

    /// Top recurring themes from notes and interactions
    let keyThemes: [String]

    /// Actionable next steps synthesized from awareness items
    let suggestedNextSteps: [String]
}
