//
//  RelationshipGraphCoordinator.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase AA: Relationship Graph — Visual Network Intelligence
//
//  @MainActor @Observable coordinator that fetches data from repositories,
//  assembles input DTOs, sends to GraphBuilderService for computation,
//  and stores resulting nodes/edges for the UI layer.
//

import Foundation
import CoreGraphics
import os

@MainActor
@Observable
final class RelationshipGraphCoordinator {

    static let shared = RelationshipGraphCoordinator()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "RelationshipGraphCoordinator")

    // MARK: - Observable State

    var graphStatus: GraphStatus = .idle
    var nodes: [GraphNode] = []
    var edges: [GraphEdge] = []
    var lastComputedAt: Date?
    var selectedNodeID: UUID?
    var hoveredNodeID: UUID?
    var progress: String = ""

    // MARK: - Filter State

    var activeRoleFilters: Set<String> = []          // Empty = show all
    var activeEdgeTypeFilters: Set<EdgeType> = []    // Empty = show all
    var showOrphanedNodes: Bool = true
    var showGhostNodes: Bool = true
    var showMeNode: Bool = false
    var minimumEdgeWeight: Double = 0.0
    var focusMode: String?

    // Filtered views (derived from full data)
    var filteredNodes: [GraphNode] = []
    var filteredEdges: [GraphEdge] = []

    // MARK: - Layout State

    var viewportCenter: CGPoint = .zero
    var viewportScale: CGFloat = 1.0

    // MARK: - Internal

    private var allNodes: [GraphNode] = []
    private var allEdges: [GraphEdge] = []
    private var buildTask: Task<Void, Never>?

    // Dependencies
    private let peopleRepository = PeopleRepository.shared
    private let contextsRepository = ContextsRepository.shared
    private let evidenceRepository = EvidenceRepository.shared
    private let notesRepository = NotesRepository.shared
    private let pipelineRepository = PipelineRepository.shared
    private let productionRepository = ProductionRepository.shared
    private let outcomeRepository = OutcomeRepository.shared
    private let meetingPrepCoordinator = MeetingPrepCoordinator.shared
    private let deducedRelationRepository = DeducedRelationRepository.shared
    private let graphBuilder = GraphBuilderService.shared

    private init() {}

    // MARK: - Status Enum

    enum GraphStatus: Equatable {
        case idle
        case computing
        case ready
        case failed
    }

    // MARK: - Public API

    /// Build the complete relationship graph from current SAM data.
    func buildGraph(bounds: CGSize = CGSize(width: 1200, height: 800)) async {
        buildTask?.cancel()
        graphStatus = .computing
        progress = "Gathering data..."

        buildTask = Task {
            do {
                // --- Fetch all data ---
                let people = try gatherPeopleInputs()
                let contexts = try gatherContextInputs()
                let referralChains = gatherReferralLinks(people: try peopleRepository.fetchAll())
                let recruitingTree = try gatherRecruitLinks()
                let coAttendanceMap = try gatherCoAttendance()
                let communicationMap = try gatherCommunicationLinks()
                let noteMentions = try gatherNoteMentions()
                let ghostMentions = try gatherGhostMentions()
                let deducedFamilyLinks = try gatherDeducedFamilyLinks()

                guard !Task.isCancelled else { return }
                progress = "Building graph..."

                // --- Build graph structure ---
                let result = await graphBuilder.buildGraph(
                    people: people,
                    contexts: contexts,
                    referralChains: referralChains,
                    recruitingTree: recruitingTree,
                    coAttendanceMap: coAttendanceMap,
                    communicationMap: communicationMap,
                    noteMentions: noteMentions,
                    ghostMentions: ghostMentions,
                    deducedFamilyLinks: deducedFamilyLinks
                )

                guard !Task.isCancelled else { return }

                // --- Try cached layout first ---
                allNodes = result.nodes
                allEdges = result.edges

                if restoreCachedLayout() {
                    progress = "Restored from cache..."
                    logger.info("Using cached layout for \(result.nodes.count) nodes")
                } else {
                    progress = "Computing layout..."

                    // --- Run force-directed layout ---
                    let laidOutNodes = await graphBuilder.layoutGraph(
                        nodes: result.nodes,
                        edges: result.edges,
                        iterations: 300,
                        bounds: bounds,
                        contextClusters: contexts
                    )

                    guard !Task.isCancelled else { return }
                    allNodes = laidOutNodes
                    cacheLayout()
                }

                // --- Finalize ---
                let nodeCount = allNodes.count
                let edgeCount = allEdges.count
                lastComputedAt = Date()
                applyFilters()
                graphStatus = .ready
                progress = "\(nodeCount) people, \(edgeCount) connections"
                logger.info("Graph ready: \(nodeCount) nodes, \(edgeCount) edges")

            } catch {
                guard !Task.isCancelled else { return }
                graphStatus = .failed
                progress = "Error: \(error.localizedDescription)"
                logger.error("Graph build failed: \(error)")
            }
        }

        await buildTask?.value
    }

    /// Merge a ghost node into an existing contact by updating all matching
    /// unresolved mentions, then rebuild the graph.
    func mergeGhost(named ghostName: String, intoPersonID personID: UUID) async {
        do {
            let affected = try notesRepository.mergeGhostMentions(
                ghostName: ghostName,
                intoPersonID: personID
            )
            logger.info("Ghost merge: '\(ghostName)' → person \(personID), \(affected) note(s) updated")
        } catch {
            logger.error("Ghost merge failed: \(error)")
        }

        invalidateLayoutCache()
        await buildGraph()
    }

    /// Rebuild if data changed since lastComputedAt.
    func rebuildIfStale(bounds: CGSize = CGSize(width: 1200, height: 800)) async {
        guard graphStatus != .computing else { return }
        await buildGraph(bounds: bounds)
    }

    /// Re-filter without full rebuild.
    func applyFilters() {
        // In focus mode, restrict to relevant nodes first
        var focusNodeIDs: Set<UUID>?
        if focusMode == "deducedRelationships" {
            var deducedNodeIDs = Set<UUID>()
            for edge in allEdges where edge.edgeType == .deducedFamily {
                deducedNodeIDs.insert(edge.sourceID)
                deducedNodeIDs.insert(edge.targetID)
            }
            // Include 1-hop neighbors for context
            var neighborIDs = deducedNodeIDs
            for edge in allEdges {
                if deducedNodeIDs.contains(edge.sourceID) { neighborIDs.insert(edge.targetID) }
                if deducedNodeIDs.contains(edge.targetID) { neighborIDs.insert(edge.sourceID) }
            }
            focusNodeIDs = neighborIDs
        }

        var visibleNodeIDs = Set<UUID>()

        filteredNodes = allNodes.filter { node in
            // Focus mode filter
            if let focusIDs = focusNodeIDs {
                guard focusIDs.contains(node.id) else { return false }
            }
            // Role filter
            if !activeRoleFilters.isEmpty {
                guard node.roleBadges.contains(where: { activeRoleFilters.contains($0) }) else { return false }
            }
            // Ghost filter
            if !showGhostNodes && node.isGhost { return false }
            // Orphaned filter
            if !showOrphanedNodes && node.isOrphaned { return false }
            visibleNodeIDs.insert(node.id)
            return true
        }

        filteredEdges = allEdges.filter { edge in
            // Edge type filter
            if !activeEdgeTypeFilters.isEmpty {
                guard activeEdgeTypeFilters.contains(edge.edgeType) else { return false }
            }
            // Weight filter
            guard edge.weight >= minimumEdgeWeight else { return false }
            // Both endpoints must be visible
            guard visibleNodeIDs.contains(edge.sourceID) && visibleNodeIDs.contains(edge.targetID) else { return false }
            return true
        }

        nodes = filteredNodes
        edges = filteredEdges
    }

    // MARK: - Data Gathering

    private func gatherPeopleInputs() throws -> [PersonGraphInput] {
        let allPeople = try peopleRepository.fetchAll()
        return allPeople.compactMap { person -> PersonGraphInput? in
            // Skip "Me" node unless showMeNode is enabled
            guard !person.isMe || showMeNode else { return nil }
            guard !person.isArchived else { return nil }

            let health = meetingPrepCoordinator.computeHealth(for: person)
            let healthLevel = mapHealthToLevel(health)
            let productionValue = person.productionRecords
                .filter { $0.status != .declined }
                .reduce(0.0) { $0 + $1.annualPremium }

            // Top outcome
            let topOutcome: String?
            if let active = try? outcomeRepository.fetchActive().first(where: { $0.linkedPerson?.id == person.id }) {
                topOutcome = active.title
            } else {
                topOutcome = nil
            }

            // Pipeline stage
            let pipelineStage: String?
            if let rs = person.recruitingStages.first {
                pipelineStage = rs.stage.rawValue
            } else {
                pipelineStage = nil
            }

            return PersonGraphInput(
                id: person.id,
                displayName: person.displayNameCache ?? person.displayName,
                roleBadges: person.roleBadges,
                relationshipHealth: healthLevel,
                productionValue: productionValue,
                photoThumbnail: person.photoThumbnailCache,
                topOutcomeText: topOutcome,
                pipelineStage: pipelineStage
            )
        }
    }

    private func gatherContextInputs() throws -> [ContextGraphInput] {
        let allContexts = try contextsRepository.fetchAll()
        return allContexts.compactMap { ctx -> ContextGraphInput? in
            let kind = ctx.kind
            guard kind == .household || kind == .business else { return nil }

            let participantIDs = ctx.participations.compactMap { $0.person?.id }
            guard participantIDs.count >= 2 else { return nil }

            return ContextGraphInput(
                contextID: ctx.id,
                contextType: kind.rawValue,
                participantIDs: participantIDs
            )
        }
    }

    private func gatherReferralLinks(people: [SamPerson]) -> [ReferralLink] {
        var links: [ReferralLink] = []
        for person in people {
            if let referrer = person.referredBy {
                links.append(ReferralLink(referrerID: referrer.id, referredID: person.id))
            }
        }
        return links
    }

    private func gatherRecruitLinks() throws -> [RecruitLink] {
        let stages = try pipelineRepository.fetchAllRecruitingStages()
        // In SAM's model, agents are recruited by the user (Me).
        // The recruiting tree is user → agent. We connect agents to "Me" node
        // or to each other based on referredBy if available.
        return stages.compactMap { rs -> RecruitLink? in
            guard let recruit = rs.person else { return nil }
            // If the agent was referred by someone, that's their recruiter
            if let recruiter = recruit.referredBy {
                return RecruitLink(
                    recruiterID: recruiter.id,
                    recruitID: recruit.id,
                    stage: rs.stage.rawValue
                )
            }
            return nil
        }
    }

    private func gatherCoAttendance() throws -> [CoAttendancePair] {
        let allEvidence = try evidenceRepository.fetchAll()
        let calendarEvents = allEvidence.filter { $0.source == .calendar }

        // Build co-attendance map: for each calendar event with 2+ linked people,
        // record a pair for each combination
        var pairCounts: [String: (UUID, UUID, Int)] = [:]

        for event in calendarEvents {
            let peopleIDs = event.linkedPeople.map(\.id).sorted { $0.uuidString < $1.uuidString }
            guard peopleIDs.count >= 2 else { continue }

            for i in 0..<peopleIDs.count {
                for j in (i + 1)..<peopleIDs.count {
                    let key = "\(peopleIDs[i])|\(peopleIDs[j])"
                    if let existing = pairCounts[key] {
                        pairCounts[key] = (existing.0, existing.1, existing.2 + 1)
                    } else {
                        pairCounts[key] = (peopleIDs[i], peopleIDs[j], 1)
                    }
                }
            }
        }

        return pairCounts.values.map { CoAttendancePair(personA: $0.0, personB: $0.1, meetingCount: $0.2) }
    }

    private func gatherCommunicationLinks() throws -> [CommLink] {
        let allEvidence = try evidenceRepository.fetchAll()
        let commEvidence = allEvidence.filter {
            $0.source == .mail || $0.source == .iMessage || $0.source == .phoneCall || $0.source == .faceTime
        }

        // Group by person pairs
        var pairData: [String: (UUID, UUID, Int, Date)] = [:]

        for evidence in commEvidence {
            let peopleIDs = evidence.linkedPeople.map(\.id).sorted { $0.uuidString < $1.uuidString }
            guard peopleIDs.count >= 2 else { continue }

            for i in 0..<peopleIDs.count {
                for j in (i + 1)..<peopleIDs.count {
                    let key = "\(peopleIDs[i])|\(peopleIDs[j])"
                    if let existing = pairData[key] {
                        pairData[key] = (existing.0, existing.1, existing.2 + 1, max(existing.3, evidence.occurredAt))
                    } else {
                        pairData[key] = (peopleIDs[i], peopleIDs[j], 1, evidence.occurredAt)
                    }
                }
            }
        }

        return pairData.values.map {
            CommLink(personA: $0.0, personB: $0.1, evidenceCount: $0.2, lastContactDate: $0.3, dominantDirection: .balanced)
        }
    }

    private func gatherNoteMentions() throws -> [MentionPair] {
        let allNotes = try notesRepository.fetchAll()
        var pairCounts: [String: (UUID, UUID, Int)] = [:]

        for note in allNotes {
            // People linked to the same note are "co-mentioned"
            let linkedIDs = note.linkedPeople.map(\.id).sorted { $0.uuidString < $1.uuidString }
            guard linkedIDs.count >= 2 else { continue }

            for i in 0..<linkedIDs.count {
                for j in (i + 1)..<linkedIDs.count {
                    let key = "\(linkedIDs[i])|\(linkedIDs[j])"
                    if let existing = pairCounts[key] {
                        pairCounts[key] = (existing.0, existing.1, existing.2 + 1)
                    } else {
                        pairCounts[key] = (linkedIDs[i], linkedIDs[j], 1)
                    }
                }
            }
        }

        return pairCounts.values.map { MentionPair(personA: $0.0, personB: $0.1, coMentionCount: $0.2) }
    }

    private func gatherGhostMentions() throws -> [GhostMention] {
        let allNotes = try notesRepository.fetchAll()
        var ghostMap: [String: (Set<UUID>, String?)] = [:]  // name → (mentioners, suggestedRole)

        for note in allNotes {
            for mention in note.extractedMentions {
                // Only include unmatched mentions (no matched person)
                guard mention.matchedPersonID == nil else { continue }
                let name = mention.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }

                let linkedPersonIDs = Set(note.linkedPeople.map(\.id))
                if var existing = ghostMap[name] {
                    existing.0.formUnion(linkedPersonIDs)
                    if existing.1 == nil { existing.1 = mention.role }
                    ghostMap[name] = existing
                } else {
                    ghostMap[name] = (linkedPersonIDs, mention.role)
                }
            }
        }

        return ghostMap.map { name, data in
            GhostMention(
                mentionedName: name,
                mentionedByIDs: Array(data.0),
                suggestedRole: data.1
            )
        }
    }

    private func gatherDeducedFamilyLinks() throws -> [DeducedFamilyLink] {
        let allRelations = try deducedRelationRepository.fetchAll()
        return allRelations.map { relation in
            DeducedFamilyLink(
                personAID: relation.personAID,
                personBID: relation.personBID,
                relationType: relation.relationTypeRawValue,
                label: relation.sourceLabel,
                isConfirmed: relation.isConfirmed,
                deducedRelationID: relation.id
            )
        }
    }

    // MARK: - Incremental Updates

    /// Update a single node's properties without full rebuild.
    /// Useful when a person's role, health, or production changes.
    func updateNode(personID: UUID) {
        guard let idx = allNodes.firstIndex(where: { $0.id == personID }) else { return }

        do {
            let allPeople = try peopleRepository.fetchAll()
            guard let person = allPeople.first(where: { $0.id == personID }) else { return }

            let health = meetingPrepCoordinator.computeHealth(for: person)
            let healthLevel = mapHealthToLevel(health)
            let productionValue = person.productionRecords
                .filter { $0.status != .declined }
                .reduce(0.0) { $0 + $1.annualPremium }
            let topOutcome: String?
            if let active = try? outcomeRepository.fetchActive().first(where: { $0.linkedPerson?.id == personID }) {
                topOutcome = active.title
            } else {
                topOutcome = nil
            }

            let oldPosition = allNodes[idx].position
            let wasPinned = allNodes[idx].isPinned

            allNodes[idx] = GraphNode(
                id: personID,
                displayName: person.displayNameCache ?? person.displayName,
                roleBadges: person.roleBadges,
                primaryRole: GraphNode.primaryRole(from: person.roleBadges),
                pipelineStage: person.recruitingStages.first?.stage.rawValue,
                relationshipHealth: healthLevel,
                productionValue: productionValue,
                isGhost: false,
                isOrphaned: allNodes[idx].isOrphaned,
                topOutcome: topOutcome,
                photoThumbnail: person.photoThumbnailCache,
                position: oldPosition,
                isPinned: wasPinned
            )

            applyFilters()
            logger.info("Incrementally updated node for person \(personID)")
        } catch {
            logger.error("Incremental node update failed: \(error)")
        }
    }

    // MARK: - Deduced Relation Confirmation

    /// Confirm a deduced relationship and rebuild to update the edge visual.
    func confirmDeducedRelation(id: UUID) {
        do {
            try deducedRelationRepository.confirm(id: id)
            invalidateLayoutCache()
            Task { await buildGraph() }
        } catch {
            logger.error("Failed to confirm deduced relation: \(error)")
        }
    }

    // MARK: - Focus Mode

    /// Activate focus mode to show only a subset of nodes/edges.
    func activateFocusMode(_ mode: String) {
        focusMode = mode
        applyFilters()
    }

    /// Clear focus mode and restore full graph.
    func clearFocusMode() {
        focusMode = nil
        applyFilters()
    }

    // MARK: - Layout Caching

    private static let cacheKey = "graphLayoutCache"
    private static let cacheTimestampKey = "graphLayoutCacheTimestamp"
    private static let cacheTTL: TimeInterval = 86400 // 24 hours

    /// Save current node positions to UserDefaults for fast restore.
    func cacheLayout() {
        let positions = allNodes.map { LayoutCacheEntry(id: $0.id, x: $0.position.x, y: $0.position.y, isPinned: $0.isPinned) }
        guard let data = try? JSONEncoder().encode(positions) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.cacheTimestampKey)
        logger.info("Cached layout for \(positions.count) nodes")
    }

    /// Restore cached positions onto existing nodes. Returns true if cache was applied.
    func restoreCachedLayout() -> Bool {
        let timestamp = UserDefaults.standard.double(forKey: Self.cacheTimestampKey)
        guard timestamp > 0, Date().timeIntervalSince1970 - timestamp < Self.cacheTTL else { return false }

        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let entries = try? JSONDecoder().decode([LayoutCacheEntry].self, from: data) else { return false }

        let entryMap = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var restored = 0

        for i in allNodes.indices {
            if let cached = entryMap[allNodes[i].id] {
                allNodes[i].position = CGPoint(x: cached.x, y: cached.y)
                allNodes[i].isPinned = cached.isPinned
                restored += 1
            }
        }

        let totalCount = allNodes.count
        guard restored > totalCount / 2 else {
            // Too many nodes changed — cache is stale, don't use it
            return false
        }

        applyFilters()
        logger.info("Restored cached layout for \(restored)/\(totalCount) nodes")
        return true
    }

    /// Clear the layout cache (forces full re-layout on next build).
    func invalidateLayoutCache() {
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        UserDefaults.standard.removeObject(forKey: Self.cacheTimestampKey)
    }

    // MARK: - Health Mapping

    private func mapHealthToLevel(_ health: RelationshipHealth) -> GraphNode.HealthLevel {
        switch health.decayRisk {
        case .none, .low:
            return .healthy
        case .moderate:
            return .cooling
        case .high:
            return .atRisk
        case .critical:
            return .cold
        }
    }
}

// MARK: - Layout Cache Entry

private struct LayoutCacheEntry: Codable {
    let id: UUID
    let x: CGFloat
    let y: CGFloat
    let isPinned: Bool
}
