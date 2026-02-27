//
//  GraphBuilderServiceTests.swift
//  SAMTests
//
//  Phase AA: Relationship Graph — Unit tests for graph engine.
//
//  Verifies: correct node/edge counts, edge types, layout convergence,
//  context clustering, ghost node creation, filter behavior.
//

import Foundation
import Testing
@preconcurrency @testable import SAM

// MARK: - Test Helpers

private func makePerson(
    id: UUID = UUID(),
    name: String = "Test Person",
    roles: [String] = ["Client"],
    health: GraphNode.HealthLevel = .healthy,
    production: Double = 0,
    pipelineStage: String? = nil
) -> PersonGraphInput {
    PersonGraphInput(
        id: id,
        displayName: name,
        roleBadges: roles,
        relationshipHealth: health,
        productionValue: production,
        photoThumbnail: nil,
        topOutcomeText: nil,
        pipelineStage: pipelineStage
    )
}

// MARK: - Graph Building Tests

@MainActor
@Suite("Graph Builder — Node & Edge Construction", .serialized)
struct GraphBuildingTests {

    let service = GraphBuilderService.shared

    @Test("Empty inputs produce empty graph")
    func emptyGraph() async throws {
        let result = await service.buildGraph(
            people: [], contexts: [], referralChains: [],
            recruitingTree: [], coAttendanceMap: [],
            communicationMap: [], noteMentions: [], ghostMentions: []
        )
        #expect(result.nodes.isEmpty)
        #expect(result.edges.isEmpty)
    }

    @Test("People without connections become orphaned nodes")
    func orphanedNodes() async throws {
        let alice = makePerson(name: "Alice")
        let bob = makePerson(name: "Bob")
        let result = await service.buildGraph(
            people: [alice, bob], contexts: [], referralChains: [],
            recruitingTree: [], coAttendanceMap: [],
            communicationMap: [], noteMentions: [], ghostMentions: []
        )
        #expect(result.nodes.count == 2)
        #expect(result.edges.count == 0)
        let allOrphaned = result.nodes.allSatisfy { $0.isOrphaned }
        #expect(allOrphaned)
    }

    @Test("Household context creates edges between all participants")
    func householdEdges() async throws {
        let alice = UUID(), bob = UUID(), charlie = UUID()
        let people = [
            makePerson(id: alice, name: "Alice"),
            makePerson(id: bob, name: "Bob"),
            makePerson(id: charlie, name: "Charlie"),
        ]
        let context = ContextGraphInput(
            contextID: UUID(),
            contextType: "Household",
            participantIDs: [alice, bob, charlie]
        )
        let result = await service.buildGraph(
            people: people, contexts: [context], referralChains: [],
            recruitingTree: [], coAttendanceMap: [],
            communicationMap: [], noteMentions: [], ghostMentions: []
        )
        #expect(result.nodes.count == 3)
        // 3 people in household = C(3,2) = 3 edges
        #expect(result.edges.count == 3)
        #expect(result.edges.allSatisfy { $0.edgeType == .household })
        // None should be orphaned
        #expect(result.nodes.allSatisfy { !$0.isOrphaned })
    }

    @Test("Business context creates business edges")
    func businessEdges() async throws {
        let alice = UUID(), bob = UUID()
        let people = [
            makePerson(id: alice, name: "Alice"),
            makePerson(id: bob, name: "Bob"),
        ]
        let context = ContextGraphInput(
            contextID: UUID(),
            contextType: "Business",
            participantIDs: [alice, bob]
        )
        let result = await service.buildGraph(
            people: people, contexts: [context], referralChains: [],
            recruitingTree: [], coAttendanceMap: [],
            communicationMap: [], noteMentions: [], ghostMentions: []
        )
        #expect(result.edges.count == 1)
        #expect(result.edges[0].edgeType == .business)
    }

    @Test("Referral chain creates directed edges")
    func referralEdges() async throws {
        let alice = UUID(), bob = UUID()
        let people = [
            makePerson(id: alice, name: "Alice"),
            makePerson(id: bob, name: "Bob"),
        ]
        let referral = ReferralLink(referrerID: alice, referredID: bob)
        let result = await service.buildGraph(
            people: people, contexts: [], referralChains: [referral],
            recruitingTree: [], coAttendanceMap: [],
            communicationMap: [], noteMentions: [], ghostMentions: []
        )
        #expect(result.edges.count == 1)
        #expect(result.edges[0].edgeType == .referral)
        #expect(result.edges[0].sourceID == alice)
        #expect(result.edges[0].targetID == bob)
        #expect(!result.edges[0].isReciprocal)
    }

    @Test("Recruiting tree creates directed edges with stage label")
    func recruitingEdges() async throws {
        let recruiter = UUID(), recruit = UUID()
        let people = [
            makePerson(id: recruiter, name: "Recruiter", roles: ["Agent"]),
            makePerson(id: recruit, name: "Recruit", roles: ["Agent"]),
        ]
        let link = RecruitLink(recruiterID: recruiter, recruitID: recruit, stage: "Studying")
        let result = await service.buildGraph(
            people: people, contexts: [], referralChains: [],
            recruitingTree: [link], coAttendanceMap: [],
            communicationMap: [], noteMentions: [], ghostMentions: []
        )
        #expect(result.edges.count == 1)
        #expect(result.edges[0].edgeType == .recruitingTree)
        #expect(result.edges[0].label == "Studying")
    }

    @Test("Co-attendance creates weighted edges")
    func coAttendanceEdges() async throws {
        let alice = UUID(), bob = UUID()
        let people = [
            makePerson(id: alice, name: "Alice"),
            makePerson(id: bob, name: "Bob"),
        ]
        let pair = CoAttendancePair(personA: alice, personB: bob, meetingCount: 5)
        let result = await service.buildGraph(
            people: people, contexts: [], referralChains: [],
            recruitingTree: [], coAttendanceMap: [pair],
            communicationMap: [], noteMentions: [], ghostMentions: []
        )
        #expect(result.edges.count == 1)
        #expect(result.edges[0].edgeType == .coAttendee)
        #expect(result.edges[0].weight == 0.5)  // 5/10 = 0.5
        #expect(result.edges[0].label == "5 meetings")
    }

    @Test("Communication links create weighted edges capped at 1.0")
    func communicationEdges() async throws {
        let alice = UUID(), bob = UUID()
        let people = [
            makePerson(id: alice, name: "Alice"),
            makePerson(id: bob, name: "Bob"),
        ]
        let link = CommLink(
            personA: alice, personB: bob,
            evidenceCount: 30,
            lastContactDate: Date(),
            dominantDirection: .balanced
        )
        let result = await service.buildGraph(
            people: people, contexts: [], referralChains: [],
            recruitingTree: [], coAttendanceMap: [],
            communicationMap: [link], noteMentions: [], ghostMentions: []
        )
        #expect(result.edges.count == 1)
        #expect(result.edges[0].edgeType == .communicationLink)
        #expect(result.edges[0].weight == 1.0)  // 30/20 capped at 1.0
        #expect(result.edges[0].isReciprocal)
    }

    @Test("Note mentions create edges between co-mentioned people")
    func noteMentionEdges() async throws {
        let alice = UUID(), bob = UUID()
        let people = [
            makePerson(id: alice, name: "Alice"),
            makePerson(id: bob, name: "Bob"),
        ]
        let mention = MentionPair(personA: alice, personB: bob, coMentionCount: 3)
        let result = await service.buildGraph(
            people: people, contexts: [], referralChains: [],
            recruitingTree: [], coAttendanceMap: [],
            communicationMap: [], noteMentions: [mention], ghostMentions: []
        )
        #expect(result.edges.count == 1)
        #expect(result.edges[0].edgeType == .mentionedTogether)
        #expect(result.edges[0].weight == 0.6)  // 3/5 = 0.6
    }

    @Test("Ghost mentions create ghost nodes and mention edges")
    func ghostMentionNodes() async throws {
        let alice = UUID()
        let people = [makePerson(id: alice, name: "Alice")]
        let ghost = GhostMention(
            mentionedName: "Unknown Person",
            mentionedByIDs: [alice],
            suggestedRole: "spouse"
        )
        let result = await service.buildGraph(
            people: people, contexts: [], referralChains: [],
            recruitingTree: [], coAttendanceMap: [],
            communicationMap: [], noteMentions: [], ghostMentions: [ghost]
        )
        #expect(result.nodes.count == 2)  // Alice + ghost
        let ghostNode = result.nodes.first { $0.isGhost }
        #expect(ghostNode != nil)
        #expect(ghostNode?.displayName == "Unknown Person")
        #expect(ghostNode?.primaryRole == "spouse")
        #expect(result.edges.count == 1)
        #expect(result.edges[0].edgeType == .mentionedTogether)
    }

    @Test("Edges referencing non-existent people are excluded")
    func edgesFilteredByExistence() async throws {
        let alice = UUID()
        let phantom = UUID()
        let people = [makePerson(id: alice, name: "Alice")]
        let referral = ReferralLink(referrerID: alice, referredID: phantom)
        let result = await service.buildGraph(
            people: people, contexts: [], referralChains: [referral],
            recruitingTree: [], coAttendanceMap: [],
            communicationMap: [], noteMentions: [], ghostMentions: []
        )
        #expect(result.edges.isEmpty)  // phantom not in people
    }

    @Test("Multiple edge types between same people all preserved")
    func multipleEdgeTypes() async throws {
        let alice = UUID(), bob = UUID()
        let people = [
            makePerson(id: alice, name: "Alice"),
            makePerson(id: bob, name: "Bob"),
        ]
        let context = ContextGraphInput(contextID: UUID(), contextType: "Household", participantIDs: [alice, bob])
        let referral = ReferralLink(referrerID: alice, referredID: bob)
        let comm = CommLink(personA: alice, personB: bob, evidenceCount: 5, lastContactDate: Date(), dominantDirection: .outbound)
        let result = await service.buildGraph(
            people: people, contexts: [context], referralChains: [referral],
            recruitingTree: [], coAttendanceMap: [],
            communicationMap: [comm], noteMentions: [], ghostMentions: []
        )
        #expect(result.edges.count == 3)  // household + referral + communication
        let edgeTypes = Set(result.edges.map(\.edgeType))
        #expect(edgeTypes.contains(.household))
        #expect(edgeTypes.contains(.referral))
        #expect(edgeTypes.contains(.communicationLink))
    }
}

// MARK: - Layout Tests

@MainActor
@Suite("Graph Builder — Force-Directed Layout", .serialized)
struct GraphLayoutTests {

    let service = GraphBuilderService.shared
    let bounds = CGSize(width: 1000, height: 800)

    @Test("Layout produces non-zero positions for all nodes")
    func layoutPositions() async throws {
        let people = (0..<10).map { i in
            makePerson(id: UUID(), name: "Person \(i)")
        }
        let result = await service.buildGraph(
            people: people, contexts: [], referralChains: [],
            recruitingTree: [], coAttendanceMap: [],
            communicationMap: [], noteMentions: [], ghostMentions: []
        )
        let laidOut = await service.layoutGraph(
            nodes: result.nodes, edges: result.edges,
            iterations: 300, bounds: bounds
        )
        #expect(laidOut.count == 10)
        // All nodes should have positions (not all at origin)
        let uniquePositions = Set(laidOut.map { "\(Int($0.position.x)),\(Int($0.position.y))" })
        #expect(uniquePositions.count > 1)
    }

    @Test("Layout converges — velocities below threshold after 300 iterations")
    func layoutConvergence() async throws {
        let ids = (0..<20).map { _ in UUID() }
        let people = ids.enumerated().map { i, id in
            makePerson(id: id, name: "Person \(i)")
        }
        // Create a chain of connections
        var referrals: [ReferralLink] = []
        for i in 0..<(ids.count - 1) {
            referrals.append(ReferralLink(referrerID: ids[i], referredID: ids[i + 1]))
        }
        let result = await service.buildGraph(
            people: people, contexts: [], referralChains: referrals,
            recruitingTree: [], coAttendanceMap: [],
            communicationMap: [], noteMentions: [], ghostMentions: []
        )
        let laidOut = await service.layoutGraph(
            nodes: result.nodes, edges: result.edges,
            iterations: 300, bounds: bounds
        )
        // After 300 iterations with damping, velocities should be near zero
        let maxVelocity = laidOut.map { sqrt($0.velocity.x * $0.velocity.x + $0.velocity.y * $0.velocity.y) }.max() ?? 0
        #expect(maxVelocity < 5.0)  // Should be well damped
    }

    @Test("Context clustering — household members stay closer than unrelated nodes")
    func contextClustering() async throws {
        let householdA = UUID(), householdB = UUID(), householdC = UUID()
        let outsider = UUID()

        let people = [
            makePerson(id: householdA, name: "Family A"),
            makePerson(id: householdB, name: "Family B"),
            makePerson(id: householdC, name: "Family C"),
            makePerson(id: outsider, name: "Outsider"),
        ]
        let context = ContextGraphInput(
            contextID: UUID(),
            contextType: "Household",
            participantIDs: [householdA, householdB, householdC]
        )
        let result = await service.buildGraph(
            people: people, contexts: [context], referralChains: [],
            recruitingTree: [], coAttendanceMap: [],
            communicationMap: [], noteMentions: [], ghostMentions: []
        )
        let laidOut = await service.layoutGraph(
            nodes: result.nodes, edges: result.edges,
            iterations: 300, bounds: bounds,
            contextClusters: [context]
        )

        let nodeMap = Dictionary(uniqueKeysWithValues: laidOut.map { ($0.id, $0.position) })
        guard let posA = nodeMap[householdA],
              let posB = nodeMap[householdB],
              let posOut = nodeMap[outsider] else {
            Issue.record("Could not find node positions")
            return
        }

        // Distance between household members should be less than distance to outsider
        let distAB = sqrt(pow(posA.x - posB.x, 2) + pow(posA.y - posB.y, 2))
        let distAOut = sqrt(pow(posA.x - posOut.x, 2) + pow(posA.y - posOut.y, 2))

        #expect(distAB < distAOut, "Household members (\(Int(distAB))px apart) should be closer than outsider (\(Int(distAOut))px)")
    }

    @Test("Empty graph layout returns empty")
    func emptyLayout() async throws {
        let result = await service.layoutGraph(
            nodes: [], edges: [], iterations: 300, bounds: bounds
        )
        #expect(result.isEmpty)
    }
}

// MARK: - Node Property Tests

@MainActor
@Suite("GraphNode — Properties", .serialized)
struct GraphNodePropertyTests {

    @Test("Primary role selects highest priority badge")
    func primaryRoleSelection() throws {
        #expect(GraphNode.primaryRole(from: ["Vendor", "Client"]) == "Client")
        #expect(GraphNode.primaryRole(from: ["Lead", "Agent"]) == "Agent")
        #expect(GraphNode.primaryRole(from: ["External Agent"]) == "External Agent")
        #expect(GraphNode.primaryRole(from: []) == nil)
    }

    @Test("Unknown roles have lower priority than known roles")
    func unknownRolePriority() throws {
        #expect(GraphNode.primaryRole(from: ["Custom Role", "Vendor"]) == "Vendor")
    }
}

// MARK: - Comprehensive Integration Test

@MainActor
@Suite("Graph Builder — Integration", .serialized)
struct GraphIntegrationTests {

    let service = GraphBuilderService.shared

    @Test("Realistic 20-person graph with mixed edge types")
    func realisticGraph() async throws {
        // Create 20 people with various roles
        let ids = (0..<20).map { _ in UUID() }
        let roles: [[String]] = [
            ["Client"], ["Client"], ["Client"], ["Client"], ["Client"],
            ["Lead"], ["Lead"], ["Lead"],
            ["Agent"], ["Agent"], ["Agent"],
            ["Vendor"], ["Vendor"],
            ["Applicant"], ["Applicant"],
            ["External Agent"], ["External Agent"],
            ["Referral Partner"],
            ["Prospect"], ["Prospect"],
        ]
        let people = ids.enumerated().map { i, id in
            makePerson(id: id, name: "Person \(i)", roles: roles[i],
                       health: i < 5 ? .healthy : (i < 10 ? .cooling : .atRisk),
                       production: i < 5 ? Double(i + 1) * 1000 : 0)
        }

        // 2 households
        let household1 = ContextGraphInput(contextID: UUID(), contextType: "Household", participantIDs: [ids[0], ids[1], ids[13]])
        let household2 = ContextGraphInput(contextID: UUID(), contextType: "Household", participantIDs: [ids[2], ids[3]])

        // 1 business
        let business = ContextGraphInput(contextID: UUID(), contextType: "Business", participantIDs: [ids[4], ids[11], ids[12]])

        // Referral chain
        let referrals = [
            ReferralLink(referrerID: ids[0], referredID: ids[5]),
            ReferralLink(referrerID: ids[0], referredID: ids[6]),
            ReferralLink(referrerID: ids[5], referredID: ids[7]),
        ]

        // Recruiting tree
        let recruiting = [
            RecruitLink(recruiterID: ids[8], recruitID: ids[9], stage: "Studying"),
            RecruitLink(recruiterID: ids[8], recruitID: ids[10], stage: "Licensed"),
        ]

        // Communications
        let comms = [
            CommLink(personA: ids[0], personB: ids[5], evidenceCount: 10, lastContactDate: Date(), dominantDirection: .outbound),
            CommLink(personA: ids[2], personB: ids[11], evidenceCount: 3, lastContactDate: Date(), dominantDirection: .balanced),
        ]

        // Co-attendance
        let coAttend = [
            CoAttendancePair(personA: ids[0], personB: ids[4], meetingCount: 3),
        ]

        // Ghost mentions
        let ghosts = [
            GhostMention(mentionedName: "Sarah Johnson", mentionedByIDs: [ids[0], ids[1]], suggestedRole: "spouse"),
        ]

        let result = await service.buildGraph(
            people: people,
            contexts: [household1, household2, business],
            referralChains: referrals,
            recruitingTree: recruiting,
            coAttendanceMap: coAttend,
            communicationMap: comms,
            noteMentions: [],
            ghostMentions: ghosts
        )

        // 20 people + 1 ghost = 21 nodes
        #expect(result.nodes.count == 21)

        // Count edges by type
        let edgesByType = Dictionary(grouping: result.edges, by: \.edgeType)
        #expect(edgesByType[.household]?.count == 4)    // C(3,2)=3 + C(2,2)=1 = 4
        #expect(edgesByType[.business]?.count == 3)     // C(3,2) = 3
        #expect(edgesByType[.referral]?.count == 3)
        #expect(edgesByType[.recruitingTree]?.count == 2)
        #expect(edgesByType[.communicationLink]?.count == 2)
        #expect(edgesByType[.coAttendee]?.count == 1)
        #expect(edgesByType[.mentionedTogether]?.count == 2)  // Ghost → ids[0] + ids[1]

        // Verify ghost node
        let ghostNode = result.nodes.first { $0.isGhost }
        #expect(ghostNode != nil)
        #expect(ghostNode?.displayName == "Sarah Johnson")

        // Verify orphaned nodes (those with no edges)
        let connectedIDs = Set(result.edges.flatMap { [$0.sourceID, $0.targetID] })
        let orphanedNodes = result.nodes.filter { $0.isOrphaned }
        for orphan in orphanedNodes {
            #expect(!connectedIDs.contains(orphan.id))
        }

        // Run layout and verify convergence
        let bounds = CGSize(width: 1200, height: 800)
        let laidOut = await service.layoutGraph(
            nodes: result.nodes, edges: result.edges,
            iterations: 300, bounds: bounds,
            contextClusters: [household1, household2, business]
        )
        #expect(laidOut.count == 21)

        // Verify all velocities are near zero (converged)
        let maxVelocity = laidOut.map { sqrt($0.velocity.x * $0.velocity.x + $0.velocity.y * $0.velocity.y) }.max() ?? 0
        #expect(maxVelocity < 5.0, "Max velocity \(maxVelocity) should be < 5.0 after convergence")

        // Verify household members are clustered (members of household1 closer to each other than to outsiders)
        let nodeMap = Dictionary(uniqueKeysWithValues: laidOut.map { ($0.id, $0.position) })
        if let pos0 = nodeMap[ids[0]], let pos1 = nodeMap[ids[1]], let pos19 = nodeMap[ids[19]] {
            let distMembers = sqrt(pow(pos0.x - pos1.x, 2) + pow(pos0.y - pos1.y, 2))
            let distOutsider = sqrt(pow(pos0.x - pos19.x, 2) + pow(pos0.y - pos19.y, 2))
            #expect(distMembers < distOutsider,
                "Household members (\(Int(distMembers))px) should be closer than outsider (\(Int(distOutsider))px)")
        }
    }
}
