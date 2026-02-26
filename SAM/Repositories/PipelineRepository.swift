//
//  PipelineRepository.swift
//  SAM
//
//  Created on February 25, 2026.
//  Phase R: Pipeline Intelligence
//
//  SwiftData CRUD for StageTransition and RecruitingStage records.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "PipelineRepository")

@MainActor
@Observable
final class PipelineRepository {

    // MARK: - Singleton

    static let shared = PipelineRepository()

    // MARK: - Container

    private var container: ModelContainer?
    private var context: ModelContext?

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    // MARK: - StageTransition: Record

    /// Record a pipeline stage transition. Re-resolves person in own context (cross-context safety).
    @discardableResult
    func recordTransition(
        personID: UUID,
        fromStage: String,
        toStage: String,
        pipelineType: PipelineType,
        notes: String? = nil
    ) throws -> StageTransition {
        guard let context else { throw RepositoryError.notConfigured }

        // Re-resolve person in this context
        let descriptor = FetchDescriptor<SamPerson>()
        let allPeople = try context.fetch(descriptor)
        let person = allPeople.first { $0.id == personID }

        let transition = StageTransition(
            person: person,
            fromStage: fromStage,
            toStage: toStage,
            pipelineType: pipelineType,
            notes: notes
        )
        context.insert(transition)
        try context.save()
        logger.info("Recorded transition: \(fromStage.isEmpty ? "(new)" : fromStage) → \(toStage) for person \(personID)")
        return transition
    }

    // MARK: - StageTransition: Fetch

    /// Fetch all transitions for a specific person, sorted by date descending.
    func fetchTransitions(forPerson personID: UUID) throws -> [StageTransition] {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<StageTransition>(
            sortBy: [SortDescriptor(\.transitionDate, order: .reverse)]
        )
        let all = try context.fetch(descriptor)
        return all.filter { $0.person?.id == personID }
    }

    /// Fetch all transitions of a given pipeline type, sorted by date descending.
    func fetchAllTransitions(pipelineType: PipelineType) throws -> [StageTransition] {
        guard let context else { throw RepositoryError.notConfigured }

        let typeRaw = pipelineType.rawValue
        let descriptor = FetchDescriptor<StageTransition>(
            sortBy: [SortDescriptor(\.transitionDate, order: .reverse)]
        )
        let all = try context.fetch(descriptor)
        return all.filter { $0.pipelineTypeRawValue == typeRaw }
    }

    /// Fetch transitions of a given pipeline type within a date window.
    func fetchTransitions(pipelineType: PipelineType, since: Date) throws -> [StageTransition] {
        guard let context else { throw RepositoryError.notConfigured }

        let typeRaw = pipelineType.rawValue
        let descriptor = FetchDescriptor<StageTransition>(
            sortBy: [SortDescriptor(\.transitionDate, order: .reverse)]
        )
        let all = try context.fetch(descriptor)
        return all.filter { $0.pipelineTypeRawValue == typeRaw && $0.transitionDate >= since }
    }

    /// Check if any transitions exist (for backfill gating).
    func hasAnyTransitions() throws -> Bool {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<StageTransition>()
        let all = try context.fetch(descriptor)
        return !all.isEmpty
    }

    // MARK: - RecruitingStage: Fetch

    /// Fetch the current recruiting stage for a person.
    func fetchRecruitingStage(forPerson personID: UUID) throws -> RecruitingStage? {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<RecruitingStage>()
        let all = try context.fetch(descriptor)
        return all.first { $0.person?.id == personID }
    }

    /// Fetch all recruiting stages.
    func fetchAllRecruitingStages() throws -> [RecruitingStage] {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<RecruitingStage>()
        return try context.fetch(descriptor)
    }

    // MARK: - RecruitingStage: Upsert

    /// Create or update the recruiting stage for a person. Enforces 1:1.
    @discardableResult
    func upsertRecruitingStage(
        personID: UUID,
        stage: RecruitingStageKind,
        notes: String? = nil
    ) throws -> RecruitingStage {
        guard let context else { throw RepositoryError.notConfigured }

        // Re-resolve person in this context
        let personDescriptor = FetchDescriptor<SamPerson>()
        let allPeople = try context.fetch(personDescriptor)
        let person = allPeople.first { $0.id == personID }

        // Check for existing
        if let existing = try fetchRecruitingStage(forPerson: personID) {
            existing.stageRawValue = stage.rawValue
            existing.enteredDate = .now
            if let notes { existing.notes = notes }
            try context.save()
            return existing
        }

        let record = RecruitingStage(
            person: person,
            stage: stage,
            notes: notes
        )
        context.insert(record)
        try context.save()
        logger.info("Created recruiting stage \(stage.rawValue) for person \(personID)")
        return record
    }

    // MARK: - RecruitingStage: Advance

    /// Advance a recruit to the next stage. Also records a StageTransition.
    func advanceRecruitingStage(
        personID: UUID,
        to newStage: RecruitingStageKind,
        notes: String? = nil
    ) throws {
        guard let context else { throw RepositoryError.notConfigured }

        let existing = try fetchRecruitingStage(forPerson: personID)
        let fromStage = existing?.stage.rawValue ?? ""

        try upsertRecruitingStage(personID: personID, stage: newStage, notes: notes)
        try recordTransition(
            personID: personID,
            fromStage: fromStage,
            toStage: newStage.rawValue,
            pipelineType: .recruiting,
            notes: notes
        )
    }

    // MARK: - Mentoring Contact

    /// Update the last mentoring contact date for a recruit.
    func updateMentoringContact(personID: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }

        guard let stage = try fetchRecruitingStage(forPerson: personID) else {
            logger.warning("No recruiting stage found for person \(personID)")
            return
        }
        stage.mentoringLastContact = .now
        try context.save()
        logger.info("Updated mentoring contact for person \(personID)")
    }

    // MARK: - Backfill

    /// Create initial transitions for existing people based on their current role badges.
    /// Returns the number of transitions created.
    @discardableResult
    func backfillInitialTransitions(allPeople: [SamPerson]) throws -> Int {
        guard let context else { throw RepositoryError.notConfigured }

        let clientStages: Set<String> = ["Lead", "Applicant", "Client"]
        var count = 0

        // Re-resolve people in this context
        let personDescriptor = FetchDescriptor<SamPerson>()
        let localPeople = try context.fetch(personDescriptor)
        let localByID = Dictionary(uniqueKeysWithValues: localPeople.map { ($0.id, $0) })

        for person in allPeople where !person.isArchived && !person.isMe {
            guard let localPerson = localByID[person.id] else { continue }
            let transitionDate = person.lastSyncedAt ?? .now

            // Client pipeline stages
            for badge in person.roleBadges where clientStages.contains(badge) {
                let transition = StageTransition(
                    person: localPerson,
                    fromStage: "",
                    toStage: badge,
                    transitionDate: transitionDate,
                    pipelineType: .client
                )
                context.insert(transition)
                count += 1
            }

            // Recruiting pipeline — Agent badge = producing
            if person.roleBadges.contains("Agent") {
                let recruitStage = RecruitingStage(
                    person: localPerson,
                    stage: .producing,
                    enteredDate: transitionDate
                )
                context.insert(recruitStage)

                let transition = StageTransition(
                    person: localPerson,
                    fromStage: "",
                    toStage: RecruitingStageKind.producing.rawValue,
                    transitionDate: transitionDate,
                    pipelineType: .recruiting
                )
                context.insert(transition)
                count += 1
            }
        }

        if count > 0 {
            try context.save()
            logger.info("Backfilled \(count) initial pipeline transitions")
        }

        return count
    }

    // MARK: - Errors

    enum RepositoryError: Error, LocalizedError {
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "PipelineRepository not configured — call configure(container:) first"
            }
        }
    }
}
