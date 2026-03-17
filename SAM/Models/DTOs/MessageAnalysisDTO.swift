//
//  MessageAnalysisDTO.swift
//  SAM
//
//  Phase M: Communications Evidence
//
//  Sendable results from on-device LLM analysis of iMessage conversation threads.
//  Crosses actor boundary from MessageAnalysisService → CommunicationsImportCoordinator.
//

import Foundation

nonisolated struct MessageAnalysisDTO: Sendable {
    let summary: String
    let topics: [String]
    let temporalEvents: [TemporalEventDTO]
    let sentiment: Sentiment
    let actionItems: [String]
    let rsvpDetections: [RSVPDetectionDTO]
    let analysisVersion: Int

    enum Sentiment: String, Sendable {
        case positive, neutral, negative, urgent
    }
}
