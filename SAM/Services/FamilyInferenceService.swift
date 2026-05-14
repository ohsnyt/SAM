//
//  FamilyInferenceService.swift
//  SAM
//
//  AI-powered family inference service. After a deduced relationship is confirmed,
//  gathers the connected family cluster and uses the LLM to infer additional
//  relationships (e.g., shared children, sibling-in-law connections) and date
//  propagation (e.g., shared anniversary). New relationships are created as
//  unconfirmed DeducedRelations for user review.
//

import Foundation
import os.log

// MARK: - Sendable DTOs for cluster data

/// A person's data within a family cluster, gathered on MainActor then sent to the actor.
struct FamilyClusterMember: Sendable {
    let id: UUID
    let name: String
    let roleBadges: [String]
    let birthday: DateComponents?
    let anniversaryDate: String?    // "YYYY-MM-DD" if available
    let contactIdentifier: String?
}

/// A deduced relation within the cluster.
struct FamilyClusterRelation: Sendable {
    let id: UUID
    let personAID: UUID
    let personBID: UUID
    let relationType: String    // DeducedRelationType.rawValue
    let sourceLabel: String
    let isConfirmed: Bool
}

/// All data about a family cluster, safe to send across actor boundaries.
struct FamilyClusterData: Sendable {
    let members: [FamilyClusterMember]
    let relations: [FamilyClusterRelation]
}

// MARK: - LLM Response DTOs

/// Codable struct matching the LLM JSON response.
private struct LLMFamilyInference: Codable {
    let inferred_relations: [LLMInferredRelation]?
    let date_propagations: [LLMDatePropagation]?
}

private struct LLMInferredRelation: Codable {
    let person_a: String
    let person_b: String
    let relation_type: String
    let label: String
    let confidence: String
    let reasoning: String?
}

private struct LLMDatePropagation: Codable {
    let person: String
    let field: String
    let value: String
    let reasoning: String?
}

// MARK: - FamilyInferenceService

actor FamilyInferenceService {

    // MARK: - Singleton

    static let shared = FamilyInferenceService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "FamilyInferenceService")

    private init() {}

    // MARK: - Public API

    /// Analyze a family cluster after a relationship confirmation and create inferred relations/enrichments.
    /// Best-effort — silently skips on AI unavailability or parse failures.
    func inferFromCluster(confirmedRelation: DeducedRelation) async {
        logger.debug("Starting family inference for relation \(confirmedRelation.id)")

        // Gather cluster data (requires MainActor for SwiftData + Contacts access)
        guard let cluster = await Self.gatherClusterData(for: confirmedRelation) else {
            logger.debug("Could not gather cluster data — skipping inference")
            return
        }

        guard cluster.members.count >= 2 else {
            logger.debug("Cluster too small (\(cluster.members.count) members) — skipping inference")
            return
        }

        // Check AI availability
        guard case .available = await AIService.shared.checkAvailability() else {
            logger.debug("AI unavailable — skipping family inference")
            return
        }

        // Build prompt
        let clusterText = formatClusterForPrompt(cluster)

        let systemInstruction = """
            You are a family relationship analyst. Given a set of people and their confirmed family relationships, \
            infer additional relationships that can be reasonably deduced.

            CRITICAL: Respond with ONLY valid JSON. No markdown code blocks.

            {
              "inferred_relations": [
                {
                  "person_a": "Jane Smith",
                  "person_b": "Tom Smith",
                  "relation_type": "parent",
                  "label": "mother",
                  "confidence": "high",
                  "reasoning": "Jane is married to John who is Tom's father"
                }
              ],
              "date_propagations": [
                {
                  "person": "Jane Smith",
                  "field": "anniversary",
                  "value": "1976-08-28",
                  "reasoning": "Spouse John has this anniversary date; they share it"
                }
              ]
            }

            Rules:
            - Only suggest relations with high or medium confidence
            - Spouse's children are very likely shared children (high confidence for marriages)
            - Anniversary dates are shared between spouses
            - Birthday propagation is never needed (each person has their own)
            - Sibling relationships can be inferred from shared parents
            - In-law relationships: use "other" type with descriptive label (e.g., "mother-in-law")
            - Do NOT re-suggest relationships that already exist in the data
            - Keep suggestions conservative — prefer fewer high-confidence suggestions over many speculative ones
            - If nothing can be inferred, return {"inferred_relations": [], "date_propagations": []}
            """

        let prompt = """
            Analyze this family cluster and infer additional relationships and date propagation:

            \(clusterText)
            """

        do {
            let responseText = try await AIService.shared.generate(
                prompt: prompt,
                systemInstruction: systemInstruction,
                task: InferenceTask(label: "Family inference", icon: "person.3", source: "FamilyInferenceService")
            )
            await Self.processResponse(responseText, cluster: cluster)
        } catch {
            logger.error("Family inference AI call failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Cluster Data Gathering

    @MainActor
    static func gatherClusterData(for relation: DeducedRelation) async -> FamilyClusterData? {
        let deducedRelationRepo = DeducedRelationRepository.shared
        let peopleRepo = PeopleRepository.shared

        // 1. Fetch all deduced relations
        guard let allRelations = try? deducedRelationRepo.fetchAll() else { return nil }

        // 2. Build adjacency graph and walk from both endpoints
        var adjacency: [UUID: Set<UUID>] = [:]
        for r in allRelations {
            adjacency[r.personAID, default: []].insert(r.personBID)
            adjacency[r.personBID, default: []].insert(r.personAID)
        }

        // BFS to find connected cluster
        var visited = Set<UUID>()
        var queue = [relation.personAID, relation.personBID]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard visited.insert(current).inserted else { continue }
            if let neighbors = adjacency[current] {
                for neighbor in neighbors where !visited.contains(neighbor) {
                    queue.append(neighbor)
                }
            }
        }

        // 3. Gather member data
        var members: [FamilyClusterMember] = []
        for personID in visited {
            guard let person = try? peopleRepo.fetch(id: personID) else { continue }
            let name = person.displayNameCache ?? person.displayName

            // Fetch contact data for birthday/anniversary
            var birthday: DateComponents? = nil
            var anniversaryDate: String? = nil

            if let contactID = person.contactIdentifier {
                let dto = await ContactsService.shared.fetchContact(identifier: contactID, keys: .detail)

                if let dto {
                    birthday = dto.birthday
                    // Find anniversary date
                    if let anniv = dto.dates.first(where: { $0.label?.lowercased() == "anniversary" }) {
                        if let dc = anniv.date {
                            var parts: [String] = []
                            if let year = dc.year { parts.append(String(format: "%04d", year)) }
                            if let month = dc.month { parts.append(String(format: "%02d", month)) }
                            if let day = dc.day { parts.append(String(format: "%02d", day)) }
                            if parts.count >= 2 {
                                anniversaryDate = parts.joined(separator: "-")
                            }
                        }
                    }
                }
            }

            members.append(FamilyClusterMember(
                id: personID,
                name: name,
                roleBadges: person.roleBadges,
                birthday: birthday,
                anniversaryDate: anniversaryDate,
                contactIdentifier: person.contactIdentifier
            ))
        }

        // 4. Filter relations to those involving cluster members
        let clusterRelations = allRelations
            .filter { visited.contains($0.personAID) && visited.contains($0.personBID) }
            .map { r in
                FamilyClusterRelation(
                    id: r.id,
                    personAID: r.personAID,
                    personBID: r.personBID,
                    relationType: r.relationTypeRawValue,
                    sourceLabel: r.sourceLabel,
                    isConfirmed: r.isConfirmed
                )
            }

        return FamilyClusterData(members: members, relations: clusterRelations)
    }

    // MARK: - Prompt Formatting

    private func formatClusterForPrompt(_ cluster: FamilyClusterData) -> String {
        var lines: [String] = []

        lines.append("PEOPLE:")
        for member in cluster.members {
            var info = "- \(member.name)"
            if !member.roleBadges.isEmpty {
                info += " (roles: \(member.roleBadges.joined(separator: ", ")))"
            }
            if let bday = member.birthday, let month = bday.month, let day = bday.day {
                if let year = bday.year {
                    info += " [birthday: \(String(format: "%04d-%02d-%02d", year, month, day))]"
                } else {
                    info += " [birthday: \(String(format: "%02d-%02d", month, day))]"
                }
            }
            if let anniv = member.anniversaryDate {
                info += " [anniversary: \(anniv)]"
            }
            lines.append(info)
        }

        lines.append("")
        lines.append("EXISTING RELATIONSHIPS:")
        for rel in cluster.relations {
            let personAName = cluster.members.first(where: { $0.id == rel.personAID })?.name ?? "?"
            let personBName = cluster.members.first(where: { $0.id == rel.personBID })?.name ?? "?"
            let status = rel.isConfirmed ? "confirmed" : "unconfirmed"
            lines.append("- \(personAName) → \(rel.sourceLabel) (\(rel.relationType)) → \(personBName) [\(status)]")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Response Processing

    @MainActor
    private static func processResponse(_ responseText: String, cluster: FamilyClusterData) {
        let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "FamilyInferenceService")
        let cleaned = JSONExtraction.extractJSON(from: responseText)

        guard let data = cleaned.data(using: .utf8) else {
            logger.warning("Could not convert response to data")
            return
        }

        let inference: LLMFamilyInference
        do {
            inference = try JSONDecoder().decode(LLMFamilyInference.self, from: data)
        } catch {
            logger.warning("Failed to parse family inference JSON: \(error.localizedDescription)")
            return
        }

        let deducedRelationRepo = DeducedRelationRepository.shared
        let enrichmentRepo = EnrichmentRepository.shared

        // Build name-to-UUID lookup (case-insensitive)
        let nameLookup = Dictionary(
            cluster.members.map { ($0.name.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Build set of existing relation pairs for dedup
        let existingPairs: Set<String> = Set(cluster.relations.map { r in
            let ids = [r.personAID.uuidString, r.personBID.uuidString].sorted()
            return "\(ids[0])|\(ids[1])|\(r.relationType)"
        })

        // Process inferred relations
        var newRelationCount = 0
        for rel in inference.inferred_relations ?? [] {
            guard let memberA = nameLookup[rel.person_a.lowercased()],
                  let memberB = nameLookup[rel.person_b.lowercased()] else {
                logger.debug("Could not match names: \(rel.person_a) / \(rel.person_b)")
                continue
            }

            // Map relation_type string to DeducedRelationType
            let relationType = DeducedRelationType(rawValue: rel.relation_type) ?? .other

            // Check for duplicate
            let ids = [memberA.id.uuidString, memberB.id.uuidString].sorted()
            let pairKey = "\(ids[0])|\(ids[1])|\(relationType.rawValue)"
            guard !existingPairs.contains(pairKey) else {
                logger.debug("Skipping duplicate relation: \(rel.person_a) → \(rel.label) → \(rel.person_b)")
                continue
            }

            // Create unconfirmed DeducedRelation
            do {
                let _ = try deducedRelationRepo.upsert(
                    personAID: memberA.id,
                    personBID: memberB.id,
                    relationType: relationType,
                    sourceLabel: rel.label
                )
                newRelationCount += 1
            } catch {
                logger.error("Failed to create inferred relation: \(error.localizedDescription)")
            }
        }

        // Process date propagations
        var enrichmentCandidates: [EnrichmentCandidate] = []
        for prop in inference.date_propagations ?? [] {
            guard let member = nameLookup[prop.person.lowercased()] else {
                logger.debug("Could not match name for date propagation: \(prop.person)")
                continue
            }

            // Only handle anniversary for now
            guard prop.field.lowercased() == "anniversary" else { continue }

            // Skip if this person already has an anniversary
            guard member.anniversaryDate == nil else { continue }

            // Need a contactIdentifier to create enrichment
            guard member.contactIdentifier != nil else { continue }

            enrichmentCandidates.append(EnrichmentCandidate(
                personID: member.id,
                field: .anniversary,
                proposedValue: prop.value,
                currentValue: nil,
                source: .deducedRelationship,
                sourceDetail: prop.reasoning ?? "Inferred from family cluster"
            ))
        }

        if !enrichmentCandidates.isEmpty {
            do {
                let inserted = try enrichmentRepo.bulkRecord(enrichmentCandidates)
                if inserted > 0 {
                    logger.debug("Queued \(inserted) anniversary enrichment(s) from family inference")
                }
            } catch {
                logger.error("Failed to queue date propagation enrichments: \(error.localizedDescription)")
            }
        }

        if newRelationCount > 0 {
            logger.debug("Created \(newRelationCount) inferred family relation(s)")
            NotificationCenter.default.post(name: .samDeducedRelationsDidChange, object: nil)
        }

        logger.info("Family inference complete: \(newRelationCount) relations, \(enrichmentCandidates.count) date propagations")
    }
}
