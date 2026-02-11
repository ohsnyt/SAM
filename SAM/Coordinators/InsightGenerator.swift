//
//  InsightGenerator.swift
//  SAM_crm
//
//  Created by Assistant on 2/11/26.
//  Phase I: Insights & Awareness
//
//  Coordinator that aggregates signals from all sources (notes, calendar, contacts)
//  and generates actionable insights for the Awareness dashboard.
//

import Foundation
import SwiftData

@MainActor
@Observable
final class InsightGenerator {
    
    // MARK: - Singleton
    
    static let shared = InsightGenerator()
    
    private init() {}
    
    // MARK: - Dependencies
    
    private var evidenceRepository = EvidenceRepository.shared
    private var peopleRepository = PeopleRepository.shared
    private var notesRepository = NotesRepository.shared
    
    // MARK: - Observable State
    
    /// Current generation status
    var generationStatus: GenerationStatus = .idle
    
    /// Timestamp of last successful generation
    var lastGeneratedAt: Date?
    
    /// Count of insights generated in last operation
    var lastInsightCount: Int = 0
    
    /// Error message if generation failed
    var lastError: String?
    
    // MARK: - Settings (UserDefaults-backed)
    
    @ObservationIgnored
    var autoGenerateEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "insightAutoGenerateEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "insightAutoGenerateEnabled") }
    }
    
    @ObservationIgnored
    var daysSinceContactThreshold: Int {
        get { UserDefaults.standard.integer(forKey: "insightDaysSinceContactThreshold") }
        set { UserDefaults.standard.set(newValue, forKey: "insightDaysSinceContactThreshold") }
    }
    
    // MARK: - Status Enum
    
    enum GenerationStatus: Equatable {
        case idle
        case generating
        case success
        case failed
        
        var displayText: String {
            switch self {
            case .idle: return "Ready"
            case .generating: return "Generating insights..."
            case .success: return "Complete"
            case .failed: return "Failed"
            }
        }
    }
    
    // MARK: - Public API
    
    /// Generate insights from all available data sources
    /// Returns array of generated insights
    func generateInsights() async -> [GeneratedInsight] {
        generationStatus = .generating
        lastError = nil
        
        print("🧠 [InsightGenerator] Starting insight generation...")
        
        do {
            var generatedInsights: [GeneratedInsight] = []
            
            // 1. Generate insights from note action items
            let noteInsights = try await generateInsightsFromNotes()
            generatedInsights.append(contentsOf: noteInsights)
            print("🧠 [InsightGenerator] Generated \(noteInsights.count) insights from notes")
            
            // 2. Generate insights from relationship patterns (no recent contact)
            let relationshipInsights = try await generateRelationshipInsights()
            generatedInsights.append(contentsOf: relationshipInsights)
            print("🧠 [InsightGenerator] Generated \(relationshipInsights.count) relationship insights")
            
            // 3. Generate insights from upcoming events
            let calendarInsights = try await generateCalendarInsights()
            generatedInsights.append(contentsOf: calendarInsights)
            print("🧠 [InsightGenerator] Generated \(calendarInsights.count) calendar insights")
            
            // 4. Deduplicate and prioritize
            let deduplicatedInsights = deduplicateInsights(generatedInsights)
            print("🧠 [InsightGenerator] Deduplicated to \(deduplicatedInsights.count) insights")
            
            // 5. Update status
            lastInsightCount = deduplicatedInsights.count
            lastGeneratedAt = .now
            generationStatus = .success
            
            print("✅ [InsightGenerator] Generated \(lastInsightCount) insights successfully")
            
            return deduplicatedInsights
            
        } catch {
            lastError = error.localizedDescription
            generationStatus = .failed
            print("❌ [InsightGenerator] Failed to generate insights: \(error)")
            return []
        }
    }
    
    /// Start auto-generation (triggered after imports or on schedule)
    func startAutoGeneration() {
        guard autoGenerateEnabled else {
            print("ℹ️ [InsightGenerator] Auto-generation disabled")
            return
        }
        
        Task {
            await generateInsights()
        }
    }
    
    // MARK: - Insight Generation Logic
    
    /// Generate insights from note action items
    private func generateInsightsFromNotes() async throws -> [GeneratedInsight] {
        var insights: [GeneratedInsight] = []
        
        // Fetch notes with pending action items
        let notesWithActions = try notesRepository.fetchNotesWithPendingActions()
        
        for note in notesWithActions {
            for actionItem in note.extractedActionItems where actionItem.status == .pending {
                let insight = GeneratedInsight(
                    kind: mapActionTypeToInsightKind(actionItem.type),
                    title: actionItem.description,
                    body: generateBodyForActionItem(actionItem, note: note),
                    personID: actionItem.linkedPersonID,
                    sourceType: .note,
                    sourceID: note.id,
                    urgency: mapActionUrgencyToInsightPriority(actionItem.urgency),
                    confidence: 0.9, // High confidence from LLM extraction
                    createdAt: .now
                )
                insights.append(insight)
            }
        }
        
        return insights
    }
    
    /// Generate insights from relationship patterns (no recent contact)
    private func generateRelationshipInsights() async throws -> [GeneratedInsight] {
        var insights: [GeneratedInsight] = []
        
        // Get threshold from settings (default 60 days)
        let threshold = daysSinceContactThreshold > 0 ? daysSinceContactThreshold : 60
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -threshold, to: .now)!
        
        // Fetch all people
        let allPeople = try peopleRepository.fetchAll()
        
        // Fetch all evidence to check for recent contact
        let allEvidence = try evidenceRepository.fetchAll()
        
        for person in allPeople {
            // Skip archived people
            guard !person.isArchived else { continue }
            
            // Find most recent evidence for this person
            let personEvidence = allEvidence.filter { evidence in
                evidence.linkedPeople.contains(where: { $0.id == person.id })
            }
            let mostRecent = personEvidence.max(by: { $0.occurredAt < $1.occurredAt })
            
            // Check if last contact was before threshold
            if let lastContact = mostRecent?.occurredAt, lastContact < cutoffDate {
                let daysSince = Calendar.current.dateComponents([.day], from: lastContact, to: .now).day ?? 0
                
                let insight = GeneratedInsight(
                    kind: .relationshipAtRisk,
                    title: "No recent contact with \(person.displayNameCache ?? person.displayName)",
                    body: "Last interaction was \(daysSince) days ago. Consider reaching out to maintain the relationship.",
                    personID: person.id,
                    sourceType: .pattern,
                    sourceID: nil,
                    urgency: daysSince > 90 ? .high : .medium,
                    confidence: 0.8,
                    createdAt: .now
                )
                insights.append(insight)
            }
        }
        
        return insights
    }
    
    /// Generate insights from upcoming calendar events
    private func generateCalendarInsights() async throws -> [GeneratedInsight] {
        var insights: [GeneratedInsight] = []
        
        // Fetch upcoming events (next 7 days)
        let startDate = Date.now
        let endDate = Calendar.current.date(byAdding: .day, value: 7, to: startDate)!
        
        let allEvidence = try evidenceRepository.fetchAll()
        let upcomingEvents = allEvidence.filter {
            $0.source == .calendar &&
            $0.occurredAt >= startDate &&
            $0.occurredAt <= endDate
        }
        
        // Generate preparation reminders for meetings
        for event in upcomingEvents {
            // Only generate insights for events with linked people
            guard !event.linkedPeople.isEmpty else { continue }
            
            let daysUntil = Calendar.current.dateComponents([.day], from: .now, to: event.occurredAt).day ?? 0
            
            if daysUntil <= 2 {
                let personNames = event.linkedPeople.map { $0.displayNameCache ?? $0.displayName }.joined(separator: ", ")
                
                let insight = GeneratedInsight(
                    kind: .followUpNeeded,
                    title: "Upcoming meeting: \(event.title)",
                    body: "Meeting with \(personNames) in \(daysUntil) day\(daysUntil == 1 ? "" : "s"). Review recent notes and prepare talking points.",
                    personID: event.linkedPeople.first?.id,
                    sourceType: .calendar,
                    sourceID: event.id,
                    urgency: daysUntil == 0 ? .high : .medium,
                    confidence: 1.0, // Calendar events are factual
                    createdAt: .now
                )
                insights.append(insight)
            }
        }
        
        return insights
    }
    
    // MARK: - Deduplication
    
    /// Remove duplicate insights based on similarity
    private func deduplicateInsights(_ insights: [GeneratedInsight]) -> [GeneratedInsight] {
        var unique: [GeneratedInsight] = []
        
        for insight in insights {
            // Check if we already have a similar insight
            let isDuplicate = unique.contains { existing in
                // Same person and same kind within 24 hours = duplicate
                existing.personID == insight.personID &&
                existing.kind == insight.kind &&
                abs(existing.createdAt.timeIntervalSince(insight.createdAt)) < 86400 // 24 hours
            }
            
            if !isDuplicate {
                unique.append(insight)
            }
        }
        
        // Sort by urgency (high first) and then by creation date (newest first)
        return unique.sorted { lhs, rhs in
            if lhs.urgency != rhs.urgency {
                return lhs.urgency.rawValue > rhs.urgency.rawValue
            }
            return lhs.createdAt > rhs.createdAt
        }
    }
    
    // MARK: - Helper Mapping Functions
    
    /// Map action item type to insight kind
    private func mapActionTypeToInsightKind(_ type: NoteActionItem.ActionType) -> InsightKind {
        switch type {
        case .updateContact:
            return .informational
        case .sendCongratulations:
            return .opportunity
        case .sendReminder:
            return .followUpNeeded
        case .scheduleMeeting:
            return .followUpNeeded
        case .createProposal:
            return .opportunity
        case .updateBeneficiary:
            return .complianceWarning
        case .generalFollowUp:
            return .followUpNeeded
        }
    }
    
    /// Map action urgency to insight priority
    private func mapActionUrgencyToInsightPriority(_ urgency: NoteActionItem.Urgency) -> InsightPriority {
        switch urgency {
        case .immediate:
            return .high
        case .soon:
            return .high
        case .standard:
            return .medium
        case .low:
            return .low
        }
    }
    
    /// Generate body text for action item insight
    private func generateBodyForActionItem(_ actionItem: NoteActionItem, note: SamNote) -> String {
        var body = actionItem.description
        
        if let suggestedText = actionItem.suggestedText, !suggestedText.isEmpty {
            body += "\n\nSuggested message: \"\(suggestedText)\""
        }
        
        if let summary = note.summary {
            body += "\n\nFrom note: \(summary)"
        }
        
        return body
    }
}

// MARK: - Supporting Types

/// Generated insight (not yet persisted to SamInsight)
struct GeneratedInsight: Identifiable, Equatable {
    let id = UUID()
    let kind: InsightKind
    let title: String
    let body: String
    let personID: UUID?
    let sourceType: InsightSourceType
    let sourceID: UUID? // Note ID, Evidence ID, etc.
    let urgency: InsightPriority
    let confidence: Double
    let createdAt: Date
}

/// Source type for insights
enum InsightSourceType: String, Codable {
    case note = "Note"
    case calendar = "Calendar"
    case contacts = "Contacts"
    case pattern = "Pattern" // Derived from analysis (e.g., no recent contact)
}

/// Priority level for insights
enum InsightPriority: Int, Codable, Comparable {
    case low = 1
    case medium = 2
    case high = 3
    
    static func < (lhs: InsightPriority, rhs: InsightPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
    
    var displayText: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
    
    var color: String {
        switch self {
        case .low: return "gray"
        case .medium: return "orange"
        case .high: return "red"
        }
    }
}
