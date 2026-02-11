//
//  NoteAnalysisCoordinator.swift
//  SAM_crm
//
//  Created by Assistant on 2/11/26.
//  Phase H: Notes & Note Intelligence
//
//  Orchestrates: note saved → LLM analysis → store results → create evidence.
//  Follows standard coordinator API pattern from context.md §2.4.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class NoteAnalysisCoordinator {
    
    // MARK: - Singleton
    
    static let shared = NoteAnalysisCoordinator()
    
    private init() {}
    
    // MARK: - Dependencies
    
    private let analysisService = NoteAnalysisService.shared
    private let notesRepository = NotesRepository.shared
    private let evidenceRepository = EvidenceRepository.shared
    private let peopleRepository = PeopleRepository.shared
    private let contextsRepository = ContextsRepository.shared
    
    // MARK: - Observable State
    
    /// Current analysis status
    var analysisStatus: AnalysisStatus = .idle
    
    /// Timestamp of last successful analysis
    var lastAnalyzedAt: Date?
    
    /// Count of notes analyzed in last batch operation
    var lastAnalysisCount: Int = 0
    
    /// Error message if analysis failed
    var lastError: String?
    
    // MARK: - Model Availability
    
    /// Check if on-device LLM is available
    func checkModelAvailability() async -> ModelAvailability {
        return await analysisService.checkAvailability()
    }
    
    // MARK: - Analysis Operations
    
    /// Analyze a single note immediately after save
    func analyzeNote(_ note: SamNote) async {
        guard !note.content.isEmpty else {
            print("⚠️ [NoteAnalysisCoordinator] Skipping analysis of empty note")
            return
        }
        
        analysisStatus = .analyzing
        lastError = nil
        
        do {
            // Step 1: Call LLM service
            let analysis = try await analysisService.analyzeNote(content: note.content)
            
            // Step 2: Convert DTO to model types
            let mentions = analysis.people.map { dto in
                ExtractedPersonMention(
                    name: dto.name,
                    role: dto.role,
                    relationshipTo: dto.relationshipTo,
                    contactUpdates: dto.contactUpdates.map { updateDTO in
                        ContactFieldUpdate(
                            field: ContactFieldUpdate.ContactUpdateField(rawValue: updateDTO.field) ?? .nickname,
                            value: updateDTO.value,
                            confidence: updateDTO.confidence
                        )
                    },
                    matchedPersonID: nil,  // Will auto-match below
                    confidence: dto.confidence
                )
            }
            
            let actionItems = analysis.actionItems.map { dto in
                NoteActionItem(
                    type: NoteActionItem.ActionType(rawValue: dto.type) ?? .generalFollowUp,
                    description: dto.description,
                    suggestedText: dto.suggestedText,
                    suggestedChannel: dto.suggestedChannel.flatMap { NoteActionItem.MessageChannel(rawValue: $0) },
                    urgency: NoteActionItem.Urgency(rawValue: dto.urgency) ?? .standard,
                    linkedPersonName: dto.personName,
                    linkedPersonID: nil,  // Will match below
                    status: .pending
                )
            }
            
            // Step 3: Auto-match extracted people to existing SamPerson records
            let matchedMentions = try autoMatchPeople(mentions)
            let matchedActions = try autoMatchActions(actionItems)
            
            // Step 4: Store analysis results
            try notesRepository.storeAnalysis(
                note: note,
                summary: analysis.summary,
                extractedMentions: matchedMentions,
                extractedActionItems: matchedActions,
                extractedTopics: analysis.topics,
                analysisVersion: analysis.analysisVersion
            )
            
            // Step 5: Create evidence item from note
            try createEvidenceFromNote(note)
            
            // Update state
            analysisStatus = .success
            lastAnalyzedAt = .now
            lastAnalysisCount = 1
            
            print("✅ [NoteAnalysisCoordinator] Analyzed note \(note.id)")
            
        } catch {
            analysisStatus = .failed
            lastError = error.localizedDescription
            print("❌ [NoteAnalysisCoordinator] Analysis failed: \(error)")
        }
    }
    
    /// Analyze all unanalyzed notes in batch
    func analyzeUnanalyzedNotes() async {
        analysisStatus = .analyzing
        lastError = nil
        
        do {
            let unanalyzedNotes = try notesRepository.fetchUnanalyzedNotes()
            
            guard !unanalyzedNotes.isEmpty else {
                analysisStatus = .idle
                print("📝 [NoteAnalysisCoordinator] No unanalyzed notes found")
                return
            }
            
            print("📝 [NoteAnalysisCoordinator] Analyzing \(unanalyzedNotes.count) notes...")
            
            var successCount = 0
            
            for note in unanalyzedNotes {
                await analyzeNote(note)
                if analysisStatus == .success {
                    successCount += 1
                }
            }
            
            analysisStatus = .success
            lastAnalyzedAt = .now
            lastAnalysisCount = successCount
            
            print("✅ [NoteAnalysisCoordinator] Batch analysis complete: \(successCount)/\(unanalyzedNotes.count) succeeded")
            
        } catch {
            analysisStatus = .failed
            lastError = error.localizedDescription
            print("❌ [NoteAnalysisCoordinator] Batch analysis failed: \(error)")
        }
    }
    
    // MARK: - Auto-Matching
    
    /// Auto-match extracted person mentions to existing SamPerson records by name
    private func autoMatchPeople(_ mentions: [ExtractedPersonMention]) throws -> [ExtractedPersonMention] {
        let allPeople = try peopleRepository.fetchAll()
        
        return mentions.map { mention in
            var matched = mention
            
            // Try to match by display name (case-insensitive)
            if let person = allPeople.first(where: {
                ($0.displayNameCache ?? $0.displayName).lowercased() == mention.name.lowercased()
            }) {
                matched.matchedPersonID = person.id
                print("🔗 [NoteAnalysisCoordinator] Auto-matched '\(mention.name)' to \(person.displayNameCache ?? person.displayName)")
            }
            
            return matched
        }
    }
    
    /// Auto-match action items to people by name
    private func autoMatchActions(_ actions: [NoteActionItem]) throws -> [NoteActionItem] {
        let allPeople = try peopleRepository.fetchAll()
        
        return actions.map { action in
            var matched = action
            
            if let personName = action.linkedPersonName,
               let person = allPeople.first(where: {
                   ($0.displayNameCache ?? $0.displayName).lowercased() == personName.lowercased()
               }) {
                matched.linkedPersonID = person.id
                print("🔗 [NoteAnalysisCoordinator] Auto-matched action to \(person.displayNameCache ?? person.displayName)")
            }
            
            return matched
        }
    }
    
    /// Create evidence item from analyzed note
    private func createEvidenceFromNote(_ note: SamNote) throws {
        // Extract IDs instead of passing model objects (different context)
        let linkedPeopleIDs = note.linkedPeople.map { $0.id }
        let linkedContextIDs = note.linkedContexts.map { $0.id }
        
        // Re-fetch people and contexts in the evidence repository's context
        let peopleInEvidenceContext = try peopleRepository.fetchAll().filter { person in
            linkedPeopleIDs.contains(person.id)
        }
        let contextsInEvidenceContext = try contextsRepository.fetchAll().filter { context in
            linkedContextIDs.contains(context.id)
        }
        
        let evidence = try evidenceRepository.create(
            sourceUID: "note:\(note.id.uuidString)",
            source: .note,
            occurredAt: note.createdAt,
            title: note.summary ?? String(note.content.prefix(50)),
            snippet: note.summary ?? String(note.content.prefix(200)),
            bodyText: note.content,
            linkedPeople: peopleInEvidenceContext,
            linkedContexts: contextsInEvidenceContext
        )
        
        print("📬 [NoteAnalysisCoordinator] Created evidence item from note: \(evidence.id)")
    }
    
    // MARK: - Status Enum
    
    enum AnalysisStatus: Equatable {
        case idle
        case analyzing
        case success
        case failed
        
        var displayText: String {
            switch self {
            case .idle: return "Ready"
            case .analyzing: return "Analyzing..."
            case .success: return "Analyzed"
            case .failed: return "Failed"
            }
        }
        
        var icon: String {
            switch self {
            case .idle: return "brain"
            case .analyzing: return "brain.head.profile"
            case .success: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.triangle.fill"
            }
        }
    }
}
