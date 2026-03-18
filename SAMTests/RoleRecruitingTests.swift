//
//  RoleRecruitingTests.swift
//  SAMTests
//
//  Tests for role recruiting models, repository, coordinator, and integration.
//

import Testing
import Foundation
import SwiftData
@testable import SAM

@Suite("Role Recruiting Tests", .serialized)
@MainActor
struct RoleRecruitingTests {

    // MARK: - Model Tests

    @Test("RoleCandidateStage order and terminal flags")
    func stageProperties() {
        #expect(RoleCandidateStage.suggested.order == 0)
        #expect(RoleCandidateStage.committed.order == 3)
        #expect(RoleCandidateStage.passed.order == 4)

        #expect(!RoleCandidateStage.suggested.isTerminal)
        #expect(!RoleCandidateStage.considering.isTerminal)
        #expect(!RoleCandidateStage.approached.isTerminal)
        #expect(RoleCandidateStage.committed.isTerminal)
        #expect(RoleCandidateStage.passed.isTerminal)
    }

    @Test("RoleCandidateStage next progression")
    func stageNext() {
        #expect(RoleCandidateStage.suggested.next == .considering)
        #expect(RoleCandidateStage.considering.next == .approached)
        #expect(RoleCandidateStage.approached.next == .committed)
        #expect(RoleCandidateStage.committed.next == nil)
        #expect(RoleCandidateStage.passed.next == nil)
    }

    @Test("RoleDefinition criteria JSON roundtrip")
    func criteriaRoundtrip() {
        let role = RoleDefinition(
            name: "Board Member",
            criteria: ["Community leader", "5+ year network", "Governance experience"]
        )
        #expect(role.criteria.count == 3)
        #expect(role.criteria[0] == "Community leader")

        role.criteria.append("New criterion")
        #expect(role.criteria.count == 4)
    }

    @Test("RoleDefinition refinementNotes JSON roundtrip")
    func refinementNotesRoundtrip() {
        let role = RoleDefinition(name: "Test Role", refinementNotes: ["too busy", "wrong area"])
        #expect(role.refinementNotes.count == 2)
        #expect(role.refinementNotes[1] == "wrong area")
    }

    @Test("RoleDefinition exclusionCriteria JSON roundtrip")
    func exclusionCriteriaRoundtrip() {
        let role = RoleDefinition(
            name: "Board Member",
            exclusionCriteria: ["Employees of ABT", "Anyone compensated by the organization"]
        )
        #expect(role.exclusionCriteria.count == 2)
        #expect(role.exclusionCriteria[0] == "Employees of ABT")

        role.exclusionCriteria.append("Vendors under contract")
        #expect(role.exclusionCriteria.count == 3)
    }

    @Test("Pre-filter excludes people who already hold the role badge")
    func preFilterExcludesRoleHolders() async {
        let roleHolder = PersonScoringProfile(
            personID: UUID(),
            displayName: "Current Board Member",
            roleBadges: ["Board Member"],
            jobTitle: nil, organization: nil, department: nil,
            linkedInHeadline: nil,
            relationshipSummary: "Active board member",
            keyThemes: [],
            recentEvidenceSnippets: [],
            noteTopics: [],
            quantitativeSignals: QuantitativeSignals(
                totalInteractions: 10, daysSinceLastInteraction: 5,
                meetingCount: 3, sharedContextCount: 1,
                referralConnectionCount: 0, socialTouchScore: nil
            )
        )

        let nonHolder = PersonScoringProfile(
            personID: UUID(),
            displayName: "Potential Candidate",
            roleBadges: ["Client"],
            jobTitle: nil, organization: nil, department: nil,
            linkedInHeadline: nil,
            relationshipSummary: "Long-time supporter",
            keyThemes: [],
            recentEvidenceSnippets: [],
            noteTopics: [],
            quantitativeSignals: QuantitativeSignals(
                totalInteractions: 5, daysSinceLastInteraction: 10,
                meetingCount: 2, sharedContextCount: 0,
                referralConnectionCount: 0, socialTouchScore: nil
            )
        )

        // Simulate the coordinator's logic: exclude person IDs with matching role badge
        let roleName = "Board Member"
        let roleHolderIDs = Set([roleHolder].filter { $0.roleBadges.contains(roleName) }.map(\.personID))

        let filtered = await RoleCandidateAnalystService.shared.preFilter(
            allPeople: [roleHolder, nonHolder],
            existingCandidatePersonIDs: roleHolderIDs,
            criteria: []
        )

        #expect(filtered.count == 1)
        #expect(filtered[0].displayName == "Potential Candidate")
    }

    @Test("RoleCandidate strength and gap signals roundtrip")
    func candidateSignalsRoundtrip() {
        let candidate = RoleCandidate(
            stage: .suggested,
            matchScore: 0.75,
            strengthSignals: ["Great networker", "Community-minded"],
            gapSignals: ["Limited availability"]
        )
        #expect(candidate.strengthSignals.count == 2)
        #expect(candidate.gapSignals.count == 1)
        #expect(candidate.stage == .suggested)
    }

    @Test("RoleCandidate stage setter works via rawValue")
    func candidateStageRawValue() {
        let candidate = RoleCandidate(stage: .suggested)
        #expect(candidate.stageRawValue == "Suggested")

        candidate.stage = .approached
        #expect(candidate.stageRawValue == "Approached")
        #expect(candidate.stage == .approached)
    }

    @Test("RoleDefinition filledCount and activeCount")
    func filledAndActiveCounts() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)
        let context = ModelContext(container)

        let role = RoleDefinition(name: "Test Role", targetCount: 3)
        context.insert(role)

        let c1 = RoleCandidate(roleDefinition: role, stage: .committed, matchScore: 0.8)
        let c2 = RoleCandidate(roleDefinition: role, stage: .considering, matchScore: 0.6)
        let c3 = RoleCandidate(roleDefinition: role, stage: .passed, matchScore: 0.4)
        let c4 = RoleCandidate(roleDefinition: role, stage: .suggested, matchScore: 0.5)
        context.insert(c1)
        context.insert(c2)
        context.insert(c3)
        context.insert(c4)
        try context.save()

        #expect(role.filledCount == 1)
        #expect(role.activeCount == 2)  // considering + suggested (not committed/passed)
    }

    // MARK: - Repository Tests

    @Test("Save and fetch role definition")
    func saveAndFetchRole() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let role = RoleDefinition(
            name: "ABT Board Member",
            roleDescription: "Governance oversight",
            idealCandidateProfile: "Community leader",
            criteria: ["5+ year network", "Available for monthly meetings"],
            targetCount: 3
        )
        try RoleRecruitingRepository.shared.saveRoleDefinition(role)

        let fetched = try RoleRecruitingRepository.shared.fetchActiveRoles()
        #expect(fetched.count == 1)
        #expect(fetched[0].name == "ABT Board Member")
        #expect(fetched[0].criteria.count == 2)
        #expect(fetched[0].targetCount == 3)
    }

    @Test("Fetch role by ID")
    func fetchRoleByID() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let role = RoleDefinition(name: "Test Role")
        try RoleRecruitingRepository.shared.saveRoleDefinition(role)

        let fetched = try RoleRecruitingRepository.shared.fetchRole(id: role.id)
        #expect(fetched != nil)
        #expect(fetched?.name == "Test Role")

        let missing = try RoleRecruitingRepository.shared.fetchRole(id: UUID())
        #expect(missing == nil)
    }

    @Test("Delete role cascades candidates")
    func deleteRoleCascade() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)
        let repo = RoleRecruitingRepository.shared

        let role = RoleDefinition(name: "To Delete", targetCount: 1)
        try repo.saveRoleDefinition(role)

        // Create a person
        let dto = makeContactDTO(identifier: "c1", givenName: "Alice", familyName: "Test")
        try PeopleRepository.shared.upsert(contact: dto)
        let people = try PeopleRepository.shared.fetchAll()
        let person = people.first!

        let candidate = RoleCandidate(person: person, roleDefinition: role, stage: .considering, matchScore: 0.7)
        try repo.saveCandidate(candidate)

        let candidatesBefore = try repo.fetchCandidates(for: role.id, includeTerminal: true)
        #expect(candidatesBefore.count == 1)

        try repo.deleteRoleDefinition(role)

        let rolesAfter = try repo.fetchActiveRoles()
        #expect(rolesAfter.isEmpty)

        // Candidate should be gone via cascade
        let allCandidates = try repo.fetchAllCandidates()
        #expect(allCandidates.isEmpty)
    }

    @Test("Fetch candidates excludes terminal by default")
    func fetchCandidatesExcludesTerminal() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)
        let repo = RoleRecruitingRepository.shared

        let role = RoleDefinition(name: "Roles Test")
        try repo.saveRoleDefinition(role)

        let c1 = RoleCandidate(roleDefinition: role, stage: .considering, matchScore: 0.6)
        let c2 = RoleCandidate(roleDefinition: role, stage: .passed, matchScore: 0.3)
        let c3 = RoleCandidate(roleDefinition: role, stage: .committed, matchScore: 0.9)
        try repo.saveCandidate(c1)
        try repo.saveCandidate(c2)
        try repo.saveCandidate(c3)

        let active = try repo.fetchCandidates(for: role.id)
        #expect(active.count == 1)  // only considering

        let all = try repo.fetchCandidates(for: role.id, includeTerminal: true)
        #expect(all.count == 3)
    }

    @Test("Fetch candidate by personID and roleID")
    func fetchCandidateByPersonAndRole() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)
        let repo = RoleRecruitingRepository.shared

        let dto = makeContactDTO(identifier: "c1", givenName: "Bob", familyName: "Test")
        try PeopleRepository.shared.upsert(contact: dto)
        let person = try PeopleRepository.shared.fetchAll().first!

        let role = RoleDefinition(name: "Role A")
        try repo.saveRoleDefinition(role)

        let candidate = RoleCandidate(person: person, roleDefinition: role, stage: .suggested, matchScore: 0.5)
        try repo.saveCandidate(candidate)

        let found = try repo.fetchCandidate(personID: person.id, roleID: role.id)
        #expect(found != nil)
        #expect(found?.matchScore == 0.5)

        let notFound = try repo.fetchCandidate(personID: UUID(), roleID: role.id)
        #expect(notFound == nil)
    }

    @Test("Add refinement note")
    func addRefinementNote() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)
        let repo = RoleRecruitingRepository.shared

        let role = RoleDefinition(name: "Refine Test", refinementNotes: ["too busy"])
        try repo.saveRoleDefinition(role)

        try repo.addRefinementNote(roleID: role.id, note: "wrong geography")

        let fetched = try repo.fetchRole(id: role.id)!
        #expect(fetched.refinementNotes.count == 2)
        #expect(fetched.refinementNotes[1] == "wrong geography")
    }

    // MARK: - Service Tests

    @Test("Pre-filter excludes existing candidates and ranks by relevance")
    func preFilterExcludesAndRanks() async {
        let existing = Set([UUID()])

        let person1 = PersonScoringProfile(
            personID: UUID(),
            displayName: "Alice Strong",
            roleBadges: ["Client"],
            jobTitle: "CPA",
            organization: "Smith & Associates",
            department: nil,
            linkedInHeadline: nil,
            relationshipSummary: "Long-time client with strong referral history",
            keyThemes: ["tax planning", "estate planning"],
            recentEvidenceSnippets: ["Meeting: Annual review", "Email: Tax questions"],
            noteTopics: ["retirement"],
            quantitativeSignals: QuantitativeSignals(
                totalInteractions: 15,
                daysSinceLastInteraction: 3,
                meetingCount: 5,
                sharedContextCount: 2,
                referralConnectionCount: 1,
                socialTouchScore: nil
            )
        )

        let person2 = PersonScoringProfile(
            personID: UUID(),
            displayName: "Bob Minimal",
            roleBadges: [],
            jobTitle: nil,
            organization: nil,
            department: nil,
            linkedInHeadline: nil,
            relationshipSummary: nil,
            keyThemes: [],
            recentEvidenceSnippets: [],
            noteTopics: [],
            quantitativeSignals: QuantitativeSignals(
                totalInteractions: 0,
                daysSinceLastInteraction: nil,
                meetingCount: 0,
                sharedContextCount: 0,
                referralConnectionCount: 0,
                socialTouchScore: nil
            )
        )

        let filtered = await RoleCandidateAnalystService.shared.preFilter(
            allPeople: [person1, person2],
            existingCandidatePersonIDs: existing,
            criteria: ["CPA", "tax planning"]
        )

        // Both should be included (neither is in existing set)
        #expect(filtered.count == 2)
        // Alice should rank higher (has more signals)
        #expect(filtered[0].displayName == "Alice Strong")
    }

    @Test("Pre-filter excludes candidates already in the pipeline")
    func preFilterExcludesExisting() async {
        let existingID = UUID()
        let person = PersonScoringProfile(
            personID: existingID,
            displayName: "Existing Candidate",
            roleBadges: [],
            jobTitle: nil,
            organization: nil,
            department: nil,
            linkedInHeadline: nil,
            relationshipSummary: nil,
            keyThemes: [],
            recentEvidenceSnippets: [],
            noteTopics: [],
            quantitativeSignals: QuantitativeSignals(
                totalInteractions: 0, daysSinceLastInteraction: nil,
                meetingCount: 0, sharedContextCount: 0,
                referralConnectionCount: 0, socialTouchScore: nil
            )
        )

        let filtered = await RoleCandidateAnalystService.shared.preFilter(
            allPeople: [person],
            existingCandidatePersonIDs: Set([existingID]),
            criteria: []
        )
        #expect(filtered.isEmpty)
    }

    // MARK: - GoalType Tests

    @Test("GoalType.roleFilling properties")
    func goalTypeRoleFilling() {
        let type = GoalType.roleFilling
        #expect(type.displayName == "Role Filling")
        #expect(type.icon == "person.badge.key")
        #expect(type.unit == "filled")
        #expect(!type.requiresFinancialPractice)
        #expect(!type.isCurrency)
    }

    // MARK: - PipelineType Tests

    @Test("PipelineType.roleRecruiting roundtrips")
    func pipelineTypeRoleRecruiting() {
        let type = PipelineType.roleRecruiting
        #expect(type.rawValue == "roleRecruiting")
        #expect(PipelineType(rawValue: "roleRecruiting") == .roleRecruiting)
    }

    // MARK: - OutcomeKind Tests

    @Test("OutcomeKind.roleFilling properties")
    func outcomeKindRoleFilling() {
        let kind = OutcomeKind.roleFilling
        #expect(kind.rawValue == "roleFilling")
        #expect(kind.messageCategory == .quick)
        #expect(kind.actionIcon == "person.badge.key")
    }

    // MARK: - GoalProgressEngine Integration

    @Test("GoalProgressEngine measures roleFilling from committed candidates")
    func goalProgressMeasuresRoleFilling() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)
        let repo = RoleRecruitingRepository.shared

        let role = RoleDefinition(name: "Progress Test Role", targetCount: 3)
        try repo.saveRoleDefinition(role)

        // Add 2 committed candidates within goal period
        let c1 = RoleCandidate(roleDefinition: role, stage: .committed, matchScore: 0.8, stageEnteredAt: .now)
        let c2 = RoleCandidate(roleDefinition: role, stage: .committed, matchScore: 0.7, stageEnteredAt: .now)
        let c3 = RoleCandidate(roleDefinition: role, stage: .considering, matchScore: 0.5)
        try repo.saveCandidate(c1)
        try repo.saveCandidate(c2)
        try repo.saveCandidate(c3)

        let goal = BusinessGoal(
            goalType: .roleFilling,
            title: "Fill 3 Board Seats",
            targetValue: 3,
            startDate: Calendar.current.date(byAdding: .day, value: -30, to: .now)!,
            endDate: Calendar.current.date(byAdding: .day, value: 60, to: .now)!
        )
        goal.roleDefinitionID = role.id

        let progress = GoalProgressEngine.shared.computeProgress(for: goal)
        #expect(progress.currentValue == 2)
        #expect(progress.targetValue == 3)
    }

    // MARK: - Coordinator Stage Advancement

    @Test("Coordinator advances stage and records transition")
    func coordinatorAdvancesStage() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)
        let repo = RoleRecruitingRepository.shared

        let dto = makeContactDTO(identifier: "c1", givenName: "Test", familyName: "Person")
        try PeopleRepository.shared.upsert(contact: dto)
        let person = try PeopleRepository.shared.fetchAll().first!

        let role = RoleDefinition(name: "Advance Test")
        try repo.saveRoleDefinition(role)

        let candidate = RoleCandidate(person: person, roleDefinition: role, stage: .suggested, matchScore: 0.7, isUserApproved: true)
        try repo.saveCandidate(candidate)

        RoleRecruitingCoordinator.shared.advanceStage(candidateID: candidate.id, to: .considering)

        // Fetch updated candidate
        let updated = try repo.fetchCandidates(for: role.id).first { $0.id == candidate.id }
        #expect(updated?.stage == .considering)

        // Verify StageTransition was recorded
        let transitions = try PipelineRepository.shared.fetchTransitions(forPerson: person.id)
        let roleTransitions = transitions.filter { $0.pipelineType == .roleRecruiting }
        #expect(!roleTransitions.isEmpty)
        #expect(roleTransitions.first?.toStage == "Considering")
    }
}
