//
//  RelationshipGraphCoordinator+Lens.swift
//  SAM
//
//  Lens loaders for the four-lens graph experience: Book of Business,
//  Referrer Productivity, Missed Nudges, Family Gaps.
//
//  Each loader builds a curated subset of the network, places nodes
//  deterministically (Me at center, waves radiating out), and streams
//  in additional waves with brief sleeps so the UI re-renders progressively.
//

import Foundation
import CoreGraphics

@MainActor
extension RelationshipGraphCoordinator {

    // MARK: - Public API

    /// Reset to the lens picker state: Me at the center, no lens active.
    func enterLensPicker() {
        currentLens = nil
        lensLoadingPhase = .idle
        lensSummary = ""
        lensAnnotations = [:]
        lensClusterLabels = []
        lensHighlightedNodeIDs = []
        clearTransientSelection()
        loadMeOnly()
    }

    /// Switch into a lens and stream its contents in. Cancels any in-flight load.
    func loadLens(_ lens: GraphLens, bounds: CGSize = CGSize(width: 1200, height: 800)) async {
        cancelInFlightLensLoad()
        currentLens = lens
        lensLoadingPhase = .anchoring
        lensSummary = ""
        lensAnnotations = [:]
        lensClusterLabels = []
        lensHighlightedNodeIDs = []
        clearTransientSelection()
        graphStatus = .ready

        let task = Task {
            switch lens {
            case .bookOfBusiness:
                await loadBookOfBusiness(bounds: bounds)
            case .referrerProductivity:
                await loadReferrerProductivity(bounds: bounds)
            case .missedNudges:
                await loadMissedNudges(bounds: bounds)
            case .familyGaps:
                await loadFamilyGaps(bounds: bounds)
            }
            if !Task.isCancelled {
                lensLoadingPhase = .complete
                lastComputedAt = Date()
            }
        }
        lensTaskBox.task = task
        await task.value
    }

    /// Cancel any in-flight lens load. Safe to call repeatedly.
    func cancelInFlightLensLoad() {
        lensTaskBox.task?.cancel()
        lensTaskBox.task = nil
    }

    // MARK: - Me-only Anchor

    /// Render just the Me node centered. Used as the picker backdrop.
    func loadMeOnly(bounds: CGSize = CGSize(width: 1200, height: 800)) {
        guard let me = try? PeopleRepository.shared.fetchMe() else {
            // No Me yet: empty graph, picker still works visually.
            allNodes = []
            allEdges = []
            nodes = []
            edges = []
            meNodeID = nil
            graphStatus = .ready
            return
        }
        meNodeID = me.id
        let center = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        let meNode = makeNode(for: me, at: center)
        allNodes = [meNode]
        allEdges = []
        nodes = [meNode]
        edges = []
        graphStatus = .ready
    }

    // MARK: - Lens 1: Book of Business

    private func loadBookOfBusiness(bounds: CGSize) async {
        let center = CGPoint(x: bounds.width / 2, y: bounds.height / 2)

        guard let me = try? PeopleRepository.shared.fetchMe() else {
            lensSummary = "Set your Me contact in Settings to use lenses."
            return
        }
        meNodeID = me.id
        var lensNodes: [GraphNode] = [makeNode(for: me, at: center)]
        var lensEdges: [GraphEdge] = []

        // Wave 1 — Active clients in a ring around Me.
        let allPeople = (try? PeopleRepository.shared.fetchAll()) ?? []
        let activeClients = allPeople.filter(isActiveClient)

        let clientRingRadius = ringRadius(for: bounds, level: 1)
        for (idx, client) in activeClients.enumerated() {
            let angle = ringAngle(index: idx, total: max(activeClients.count, 1))
            let pos = CGPoint(
                x: center.x + clientRingRadius * cos(angle),
                y: center.y + clientRingRadius * sin(angle)
            )
            lensNodes.append(makeNode(for: client, at: pos))
            lensEdges.append(meEdge(meID: me.id, personID: client.id, role: "Client"))
        }
        lensSummary = "\(activeClients.count) active client\(activeClients.count == 1 ? "" : "s")"
        lensLoadingPhase = .primary
        commitLensSnapshot(nodes: lensNodes, edges: lensEdges)
        try? await Task.sleep(for: .milliseconds(120))
        if Task.isCancelled { return }

        // Wave 2 — Family ties (deduced + reference) for the active clients.
        let clientIDs = Set(activeClients.map(\.id))
        let allRelations = (try? DeducedRelationRepository.shared.fetchAll()) ?? []
        let activeRelations = allRelations.filter { !$0.isRejected }

        var addedFamilyNodeIDs = Set<UUID>()
        var clientsWithFamily = Set<UUID>()
        let familyRingRadius = ringRadius(for: bounds, level: 2)

        for relation in activeRelations {
            let aIn = clientIDs.contains(relation.personAID)
            let bIn = clientIDs.contains(relation.personBID)
            guard aIn || bIn else { continue }

            let anchorID = aIn ? relation.personAID : relation.personBID
            let otherID  = aIn ? relation.personBID : relation.personAID

            clientsWithFamily.insert(anchorID)

            // If "other" is also a client, just add a family edge between them — no new node.
            if clientIDs.contains(otherID) {
                clientsWithFamily.insert(otherID)
                lensEdges.append(GraphEdge(
                    sourceID: anchorID,
                    targetID: otherID,
                    edgeType: .deducedFamily,
                    weight: 0.7,
                    label: relation.sourceLabel,
                    isReciprocal: true,
                    communicationDirection: nil,
                    deducedRelationID: relation.id,
                    isConfirmedDeduction: relation.isConfirmed
                ))
                continue
            }

            // Add the family member as an outer-ring node positioned near anchor.
            guard !addedFamilyNodeIDs.contains(otherID) else { continue }
            guard let otherPerson = allPeople.first(where: { $0.id == otherID }) else { continue }

            let anchorPos = lensNodes.first(where: { $0.id == anchorID })?.position ?? center
            let outwardAngle = atan2(anchorPos.y - center.y, anchorPos.x - center.x)
            // Spread family members slightly off the anchor's outward radial.
            let jitter = CGFloat(addedFamilyNodeIDs.count % 3 - 1) * 0.08
            let pos = CGPoint(
                x: center.x + familyRingRadius * cos(outwardAngle + jitter),
                y: center.y + familyRingRadius * sin(outwardAngle + jitter)
            )
            lensNodes.append(makeNode(for: otherPerson, at: pos))
            addedFamilyNodeIDs.insert(otherID)
            lensEdges.append(GraphEdge(
                sourceID: anchorID,
                targetID: otherID,
                edgeType: .deducedFamily,
                weight: 0.7,
                label: relation.sourceLabel,
                isReciprocal: true,
                communicationDirection: nil,
                deducedRelationID: relation.id,
                isConfirmedDeduction: relation.isConfirmed
            ))
        }

        // Family references discovered from notes (may be ghosts when unmatched).
        for client in activeClients {
            for ref in client.familyReferences {
                clientsWithFamily.insert(client.id)
                if let linkedID = ref.linkedPersonID {
                    // If linked person is a client, an edge already covers it via deduced loop.
                    // Otherwise add a family-reference edge if not already present.
                    let edgeExists = lensEdges.contains {
                        ($0.sourceID == client.id && $0.targetID == linkedID) ||
                        ($0.sourceID == linkedID && $0.targetID == client.id)
                    }
                    if !edgeExists, let linkedPerson = allPeople.first(where: { $0.id == linkedID }) {
                        if !lensNodes.contains(where: { $0.id == linkedID }) {
                            let anchorPos = lensNodes.first(where: { $0.id == client.id })?.position ?? center
                            let outwardAngle = atan2(anchorPos.y - center.y, anchorPos.x - center.x)
                            let pos = CGPoint(
                                x: center.x + familyRingRadius * cos(outwardAngle + 0.05),
                                y: center.y + familyRingRadius * sin(outwardAngle + 0.05)
                            )
                            lensNodes.append(makeNode(for: linkedPerson, at: pos))
                        }
                        lensEdges.append(GraphEdge(
                            sourceID: client.id,
                            targetID: linkedID,
                            edgeType: .familyReference,
                            weight: 0.6,
                            label: ref.relationship,
                            isReciprocal: true,
                            communicationDirection: nil
                        ))
                    }
                }
                // Ghost family references (unmatched names) intentionally omitted from
                // Book of Business to keep the picture about real people; they show
                // up in the gap counters instead.
            }
        }

        lensLoadingPhase = .secondary
        commitLensSnapshot(nodes: lensNodes, edges: lensEdges)
        try? await Task.sleep(for: .milliseconds(140))
        if Task.isCancelled { return }

        // Wave 3 — Referrers (people who introduced clients).
        let referrerRingRadius = ringRadius(for: bounds, level: 0)  // closer to Me
        var addedReferrerIDs = Set<UUID>()

        for client in activeClients {
            guard let referrer = client.referredBy else { continue }
            // Don't duplicate if referrer is already in the canvas (could be Me, another client, or new).
            if !lensNodes.contains(where: { $0.id == referrer.id }) {
                guard !addedReferrerIDs.contains(referrer.id) else { continue }
                let anchorPos = lensNodes.first(where: { $0.id == client.id })?.position ?? center
                // Place referrer slightly toward Me on the radial of their referee.
                let inwardAngle = atan2(anchorPos.y - center.y, anchorPos.x - center.x)
                let pos = CGPoint(
                    x: center.x + referrerRingRadius * cos(inwardAngle),
                    y: center.y + referrerRingRadius * sin(inwardAngle)
                )
                lensNodes.append(makeNode(for: referrer, at: pos))
                addedReferrerIDs.insert(referrer.id)
            }
            lensEdges.append(GraphEdge(
                sourceID: referrer.id,
                targetID: client.id,
                edgeType: .referral,
                weight: 0.7,
                label: "referred",
                isReciprocal: false,
                communicationDirection: nil
            ))
        }

        // Highlight singletons (clients without family).
        let singletonIDs = clientIDs.subtracting(clientsWithFamily)
        lensHighlightedNodeIDs = singletonIDs

        // Build per-person lens annotations.
        var annotations: [UUID: String] = [:]
        for client in activeClients where singletonIDs.contains(client.id) {
            annotations[client.id] = "No family linked yet"
        }
        for client in activeClients {
            if let referrer = client.referredBy {
                annotations[client.id] = "Referred by \(referrer.displayName)"
            }
        }
        lensAnnotations = annotations

        lensLoadingPhase = .tertiary
        commitLensSnapshot(nodes: lensNodes, edges: lensEdges)

        let withFamily = clientsWithFamily.count
        let totalClients = activeClients.count
        let referrerCount = addedReferrerIDs.count
        lensSummary = "\(totalClients) clients · \(withFamily) with family · \(referrerCount) referrers"
    }

    // MARK: - Lens 2: Referrer Productivity

    private func loadReferrerProductivity(bounds: CGSize) async {
        let center = CGPoint(x: bounds.width / 2, y: bounds.height / 2)

        guard let me = try? PeopleRepository.shared.fetchMe() else {
            lensSummary = "Set your Me contact in Settings to use lenses."
            return
        }
        meNodeID = me.id

        let allPeople = (try? PeopleRepository.shared.fetchAll()) ?? []

        // Build referrer → referred-clients map (clients only).
        var referrerToReferees: [UUID: [SamPerson]] = [:]
        for person in allPeople where isActiveClient(person) {
            if let referrer = person.referredBy {
                referrerToReferees[referrer.id, default: []].append(person)
            }
        }
        // Sort referrers by # of clients introduced (descending).
        let referrerEntries = referrerToReferees
            .compactMap { (id, referees) -> (SamPerson, [SamPerson])? in
                guard let referrer = allPeople.first(where: { $0.id == id }) else { return nil }
                return (referrer, referees)
            }
            .sorted { $0.1.count > $1.1.count }

        var lensNodes: [GraphNode] = [makeNode(for: me, at: center)]
        var lensEdges: [GraphEdge] = []
        let referrerRingRadius = ringRadius(for: bounds, level: 1)

        // Wave 1 — Top referrers placed around Me, sized by # introduced.
        var refereeCountByReferrer: [UUID: Int] = [:]
        var topThreeIDs = Set<UUID>()
        for (idx, entry) in referrerEntries.enumerated() {
            let (referrer, referees) = entry
            let angle = ringAngle(index: idx, total: max(referrerEntries.count, 1))
            let pos = CGPoint(
                x: center.x + referrerRingRadius * cos(angle),
                y: center.y + referrerRingRadius * sin(angle)
            )
            lensNodes.append(makeNode(for: referrer, at: pos))
            lensEdges.append(GraphEdge(
                sourceID: me.id,
                targetID: referrer.id,
                edgeType: .roleRelationship,
                weight: 0.4,
                label: "referrer",
                isReciprocal: false,
                communicationDirection: .outbound
            ))
            refereeCountByReferrer[referrer.id] = referees.count
            if idx < 3 { topThreeIDs.insert(referrer.id) }
        }
        lensHighlightedNodeIDs = topThreeIDs
        lensSummary = "\(referrerEntries.count) referrer\(referrerEntries.count == 1 ? "" : "s") have introduced clients"
        lensLoadingPhase = .primary
        commitLensSnapshot(nodes: lensNodes, edges: lensEdges)
        try? await Task.sleep(for: .milliseconds(140))
        if Task.isCancelled { return }

        // Wave 2 — Referees fanned out from each referrer.
        let refereeRingRadius = ringRadius(for: bounds, level: 2)
        for (idx, entry) in referrerEntries.enumerated() {
            let (referrer, referees) = entry
            let referrerAngle = ringAngle(index: idx, total: max(referrerEntries.count, 1))
            let totalReferees = max(referees.count, 1)
            let arc: CGFloat = .pi / 4  // each referrer gets a 45° fan
            for (rIdx, referee) in referees.enumerated() {
                let offset = (CGFloat(rIdx) / CGFloat(totalReferees) - 0.5) * arc
                let pos = CGPoint(
                    x: center.x + refereeRingRadius * cos(referrerAngle + offset),
                    y: center.y + refereeRingRadius * sin(referrerAngle + offset)
                )
                if !lensNodes.contains(where: { $0.id == referee.id }) {
                    lensNodes.append(makeNode(for: referee, at: pos))
                }
                lensEdges.append(GraphEdge(
                    sourceID: referrer.id,
                    targetID: referee.id,
                    edgeType: .referral,
                    weight: 0.7,
                    label: "referred",
                    isReciprocal: false,
                    communicationDirection: nil
                ))
            }
        }

        // Compute per-referrer stats annotations (Swift, instant).
        var annotations: [UUID: String] = [:]
        for (referrer, referees) in referrerEntries {
            let totalPremium = referees.reduce(0.0) { sum, p in
                sum + p.productionRecords.filter { $0.status != .declined }
                    .reduce(0.0) { $0 + $1.annualPremium }
            }
            let count = referees.count
            let plural = count == 1 ? "client" : "clients"
            if totalPremium > 0 {
                annotations[referrer.id] = "\(count) \(plural) · $\(formatCompactDollars(totalPremium)) premium"
            } else {
                annotations[referrer.id] = "\(count) \(plural) introduced"
            }
        }
        lensAnnotations = annotations
        lensLoadingPhase = .secondary
        commitLensSnapshot(nodes: lensNodes, edges: lensEdges)
    }

    // MARK: - Lens 3: Missed Nudges

    private func loadMissedNudges(bounds: CGSize) async {
        let center = CGPoint(x: bounds.width / 2, y: bounds.height / 2)

        guard let me = try? PeopleRepository.shared.fetchMe() else {
            lensSummary = "Set your Me contact in Settings to use lenses."
            return
        }
        meNodeID = me.id

        let dismissedAll = (try? OutcomeRepository.shared.fetchDismissed()) ?? []
        let dismissed = dismissedAll.filter { $0.dismissedAt != nil && $0.linkedPerson != nil }

        // Group by outcomeKind → cluster.
        var clusters: [OutcomeKind: [SamOutcome]] = [:]
        for outcome in dismissed {
            clusters[outcome.outcomeKind, default: []].append(outcome)
        }
        // Order clusters by count, descending.
        let clusterOrder = clusters.keys.sorted { (clusters[$0]?.count ?? 0) > (clusters[$1]?.count ?? 0) }

        var lensNodes: [GraphNode] = [makeNode(for: me, at: center)]
        var lensEdges: [GraphEdge] = []
        var clusterLabels: [(center: CGPoint, label: String, count: Int)] = []
        var annotations: [UUID: String] = [:]

        let clusterRingRadius = ringRadius(for: bounds, level: 2)
        let nodeRingRadius = ringRadius(for: bounds, level: 1)
        let clusterCount = max(clusterOrder.count, 1)

        for (cIdx, kind) in clusterOrder.enumerated() {
            let outcomes = clusters[kind] ?? []
            let baseAngle = ringAngle(index: cIdx, total: clusterCount)
            // Cluster header position
            let headerPos = CGPoint(
                x: center.x + clusterRingRadius * cos(baseAngle),
                y: center.y + clusterRingRadius * sin(baseAngle)
            )
            clusterLabels.append((headerPos, missedNudgeClusterLabel(for: kind), outcomes.count))

            // Nodes radiate from cluster header toward Me.
            let arc: CGFloat = .pi / 3  // 60° per cluster
            let total = max(outcomes.count, 1)
            for (oIdx, outcome) in outcomes.enumerated() {
                guard let person = outcome.linkedPerson else { continue }
                let offset = (CGFloat(oIdx) / CGFloat(total) - 0.5) * arc
                let pos = CGPoint(
                    x: center.x + nodeRingRadius * cos(baseAngle + offset),
                    y: center.y + nodeRingRadius * sin(baseAngle + offset)
                )
                if !lensNodes.contains(where: { $0.id == person.id }) {
                    lensNodes.append(makeNode(for: person, at: pos))
                }
                let daysSince = daysBetween(outcome.dismissedAt ?? Date(), .now)
                let action = outcome.suggestedNextStep ?? outcome.title
                annotations[person.id] = "\(daysSince)d ago · \(action)"
            }
        }

        lensClusterLabels = clusterLabels
        lensAnnotations = annotations
        lensSummary = "\(dismissed.count) missed nudge\(dismissed.count == 1 ? "" : "s") · \(clusterOrder.count) cluster\(clusterOrder.count == 1 ? "" : "s")"
        lensLoadingPhase = .primary
        commitLensSnapshot(nodes: lensNodes, edges: lensEdges)
    }

    // MARK: - Lens 4: Family Gaps

    private func loadFamilyGaps(bounds: CGSize) async {
        let center = CGPoint(x: bounds.width / 2, y: bounds.height / 2)

        guard let me = try? PeopleRepository.shared.fetchMe() else {
            lensSummary = "Set your Me contact in Settings to use lenses."
            return
        }
        meNodeID = me.id

        let allPeople = (try? PeopleRepository.shared.fetchAll()) ?? []
        let activeClients = allPeople.filter(isActiveClient)

        // Identify clients with NO family signal: empty familyReferences AND no DeducedRelation.
        let allRelations = (try? DeducedRelationRepository.shared.fetchAll()) ?? []
        let activeRelations = allRelations.filter { !$0.isRejected }
        var clientsWithFamily = Set<UUID>()
        for relation in activeRelations {
            clientsWithFamily.insert(relation.personAID)
            clientsWithFamily.insert(relation.personBID)
        }
        let gapClients = activeClients.filter { client in
            guard !clientsWithFamily.contains(client.id) else { return false }
            return client.familyReferences.isEmpty
        }

        var lensNodes: [GraphNode] = [makeNode(for: me, at: center)]
        var lensEdges: [GraphEdge] = []
        let ringR = ringRadius(for: bounds, level: 1)
        for (idx, client) in gapClients.enumerated() {
            let angle = ringAngle(index: idx, total: max(gapClients.count, 1))
            let pos = CGPoint(
                x: center.x + ringR * cos(angle),
                y: center.y + ringR * sin(angle)
            )
            lensNodes.append(makeNode(for: client, at: pos))
            lensEdges.append(meEdge(meID: me.id, personID: client.id, role: "Client"))
        }
        lensHighlightedNodeIDs = Set(gapClients.map(\.id))
        lensAnnotations = Dictionary(uniqueKeysWithValues: gapClients.map {
            ($0.id, "No family info captured yet")
        })
        lensSummary = "\(gapClients.count) client\(gapClients.count == 1 ? "" : "s") without family context"
        lensLoadingPhase = .primary
        commitLensSnapshot(nodes: lensNodes, edges: lensEdges)
    }

    // MARK: - Helpers

    private func clearTransientSelection() {
        selectedNodeIDs = []
        selectionAnchorID = nil
        hoveredNodeID = nil
    }

    private func commitLensSnapshot(nodes lensNodes: [GraphNode], edges lensEdges: [GraphEdge]) {
        allNodes = lensNodes
        allEdges = lensEdges
        nodes = lensNodes
        edges = lensEdges
    }

    private func makeNode(for person: SamPerson, at position: CGPoint) -> GraphNode {
        let health = MeetingPrepCoordinator.shared.computeHealth(for: person)
        let healthLevel = mapHealthToLevel(health)
        let productionValue = person.productionRecords
            .filter { $0.status != .declined }
            .reduce(0.0) { $0 + $1.annualPremium }
        return GraphNode(
            id: person.id,
            displayName: person.displayNameCache ?? person.displayName,
            roleBadges: person.roleBadges,
            primaryRole: GraphNode.primaryRole(from: person.roleBadges),
            pipelineStage: person.recruitingStages.first?.stage.rawValue,
            relationshipHealth: healthLevel,
            productionValue: productionValue,
            isGhost: false,
            isOrphaned: false,
            topOutcome: nil,
            photoThumbnail: person.photoThumbnailCache,
            position: position
        )
    }

    private func meEdge(meID: UUID, personID: UUID, role: String) -> GraphEdge {
        GraphEdge(
            sourceID: meID,
            targetID: personID,
            edgeType: .roleRelationship,
            weight: 0.5,
            label: role,
            isReciprocal: false,
            communicationDirection: .outbound
        )
    }

    private func isActiveClient(_ person: SamPerson) -> Bool {
        guard !person.isMe else { return false }
        guard !person.isArchived else { return false }
        guard person.lifecycleStatus == .active else { return false }
        guard person.roleBadges.contains("Client") else { return false }
        return person.hasMeaningfulSignal
    }

    /// Three concentric rings for lens layouts: 0 = inner (referrers), 1 = middle (clients), 2 = outer (family).
    private func ringRadius(for bounds: CGSize, level: Int) -> CGFloat {
        let base = min(bounds.width, bounds.height)
        switch level {
        case 0:  return base * 0.18
        case 1:  return base * 0.32
        default: return base * 0.46
        }
    }

    private func ringAngle(index: Int, total: Int) -> CGFloat {
        guard total > 0 else { return 0 }
        let step = (2 * CGFloat.pi) / CGFloat(total)
        // Start at -π/2 so the first node sits at top.
        return -.pi / 2 + step * CGFloat(index)
    }

    private func daysBetween(_ start: Date, _ end: Date) -> Int {
        let interval = end.timeIntervalSince(start)
        return max(0, Int(interval / 86_400))
    }

    private func formatCompactDollars(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000     { return String(format: "%.0fk", value / 1_000) }
        return String(format: "%.0f", value)
    }

    private func missedNudgeClusterLabel(for kind: OutcomeKind) -> String {
        switch kind {
        case .followUp:        return "No follow-up after meeting"
        case .outreach:        return "Going cold"
        case .preparation:     return "Skipped meeting prep"
        case .proposal:        return "Proposal stalled"
        case .growth:          return "Growth activity skipped"
        case .training:        return "Training deferred"
        case .compliance:      return "Compliance deferred"
        case .contentCreation: return "Content not posted"
        case .setup:           return "Setup skipped"
        case .roleFilling:     return "Recruiting paused"
        case .userTask:        return "Open commitments"
        case .commitment:      return "Promise unkept"
        }
    }
}

