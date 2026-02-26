//
//  PipelineTracker.swift
//  SAM
//
//  Created on February 25, 2026.
//  Phase R: Pipeline Intelligence
//
//  Computes pipeline metrics (conversion rates, velocity, time-in-stage,
//  stuck people, mentoring alerts) from StageTransition and RecruitingStage data.
//  All computation is deterministic Swift — no LLM.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "PipelineTracker")

@MainActor
@Observable
final class PipelineTracker {

    // MARK: - Singleton

    static let shared = PipelineTracker()

    private init() {}

    // MARK: - Observable State

    var clientFunnel = FunnelSnapshot()
    var clientConversionRates = ConversionRates()
    var clientTimeInStage = TimeInStageMetrics()
    var clientStuckPeople: [StuckPerson] = []
    var clientVelocity: Double = 0
    var recentClientTransitions: [RecentTransition] = []

    var recruitFunnel: [RecruitingStageSummary] = []
    var recruitLicensingRate: Double = 0
    var recruitMentoringAlerts: [MentoringAlert] = []

    // Production metrics (Phase S)
    var productionByStatus: [ProductionStatusSummary] = []
    var productionByType: [ProductionTypeSummary] = []
    var productionTotalPremium: Double = 0
    var productionPendingCount: Int = 0
    var productionPendingAging: [PendingAgingItem] = []
    var productionAllRecords: [ProductionRecordItem] = []
    var productionWindowDays: Int = 90

    var configWindowDays: Int = 90

    // MARK: - Refresh

    func refresh() {
        refreshClientPipeline()
        refreshRecruitingPipeline()
        refreshProduction()
    }

    // MARK: - Client Pipeline

    private func refreshClientPipeline() {
        do {
            // Funnel counts from current role badges
            let allPeople = try PeopleRepository.shared.fetchAll()
            let active = allPeople.filter { !$0.isArchived && !$0.isMe }

            let leads = active.filter { $0.roleBadges.contains("Lead") }
            let applicants = active.filter { $0.roleBadges.contains("Applicant") }
            let clients = active.filter { $0.roleBadges.contains("Client") }

            clientFunnel = FunnelSnapshot(
                leadCount: leads.count,
                applicantCount: applicants.count,
                clientCount: clients.count
            )

            // Conversion rates from transitions within window
            let windowStart = Calendar.current.date(
                byAdding: .day, value: -configWindowDays, to: .now
            ) ?? .now
            let windowTransitions = try PipelineRepository.shared.fetchTransitions(
                pipelineType: .client, since: windowStart
            )

            let leadToApplicant = windowTransitions.filter {
                $0.fromStage == "Lead" && $0.toStage == "Applicant"
            }.count
            let applicantToClient = windowTransitions.filter {
                $0.fromStage == "Applicant" && $0.toStage == "Client"
            }.count

            // Count people who were leads in the window (entered as lead or were lead)
            let totalLeadEntries = windowTransitions.filter {
                $0.toStage == "Lead"
            }.count
            let totalApplicantEntries = windowTransitions.filter {
                $0.toStage == "Applicant"
            }.count

            clientConversionRates = ConversionRates(
                leadToApplicant: totalLeadEntries > 0
                    ? Double(leadToApplicant) / Double(totalLeadEntries) : 0,
                applicantToClient: totalApplicantEntries > 0
                    ? Double(applicantToClient) / Double(totalApplicantEntries) : 0
            )

            // Time-in-stage: average days between paired transitions
            let allClientTransitions = try PipelineRepository.shared.fetchAllTransitions(
                pipelineType: .client
            )
            clientTimeInStage = computeTimeInStage(from: allClientTransitions)

            // Velocity: transitions per week within window
            let weeksInWindow = max(1.0, Double(configWindowDays) / 7.0)
            let windowForwardTransitions = windowTransitions.filter { !$0.toStage.isEmpty && !$0.fromStage.isEmpty }
            clientVelocity = Double(windowForwardTransitions.count) / weeksInWindow

            // Stuck people
            let now = Date.now
            let leadThreshold: TimeInterval = 30 * 24 * 60 * 60
            let applicantThreshold: TimeInterval = 14 * 24 * 60 * 60
            var stuck: [StuckPerson] = []

            for person in leads {
                let lastActivity = person.linkedEvidence.map(\.occurredAt).max()
                    ?? person.lastSyncedAt
                if let last = lastActivity {
                    let gap = now.timeIntervalSince(last)
                    if gap >= leadThreshold {
                        stuck.append(StuckPerson(
                            personID: person.id,
                            personName: person.displayNameCache ?? person.displayName,
                            stage: "Lead",
                            daysStuck: Int(gap / (24 * 60 * 60))
                        ))
                    }
                }
            }

            for person in applicants {
                let lastActivity = person.linkedEvidence.map(\.occurredAt).max()
                    ?? person.lastSyncedAt
                if let last = lastActivity {
                    let gap = now.timeIntervalSince(last)
                    if gap >= applicantThreshold {
                        stuck.append(StuckPerson(
                            personID: person.id,
                            personName: person.displayNameCache ?? person.displayName,
                            stage: "Applicant",
                            daysStuck: Int(gap / (24 * 60 * 60))
                        ))
                    }
                }
            }

            clientStuckPeople = stuck.sorted { $0.daysStuck > $1.daysStuck }

            // Recent transitions (last 10)
            let recent = Array(allClientTransitions.prefix(10))
            recentClientTransitions = recent.map { t in
                RecentTransition(
                    id: t.id,
                    personName: t.person?.displayNameCache ?? t.person?.displayName ?? "Unknown",
                    personID: t.person?.id,
                    fromStage: t.fromStage,
                    toStage: t.toStage,
                    date: t.transitionDate
                )
            }

        } catch {
            logger.error("Failed to refresh client pipeline: \(error)")
        }
    }

    private func computeTimeInStage(from transitions: [StageTransition]) -> TimeInStageMetrics {
        // Group transitions by person
        var byPerson: [UUID: [StageTransition]] = [:]
        for t in transitions {
            guard let pid = t.person?.id else { continue }
            byPerson[pid, default: []].append(t)
        }

        var leadDays: [Double] = []
        var applicantDays: [Double] = []

        for (_, personTransitions) in byPerson {
            let sorted = personTransitions.sorted { $0.transitionDate < $1.transitionDate }
            for i in 0..<sorted.count {
                let t = sorted[i]
                // Find the next transition from the same stage
                if t.toStage == "Lead" {
                    if let nextT = sorted.dropFirst(i + 1).first(where: { $0.fromStage == "Lead" }) {
                        let days = nextT.transitionDate.timeIntervalSince(t.transitionDate) / (24 * 60 * 60)
                        if days > 0 { leadDays.append(days) }
                    }
                }
                if t.toStage == "Applicant" {
                    if let nextT = sorted.dropFirst(i + 1).first(where: { $0.fromStage == "Applicant" }) {
                        let days = nextT.transitionDate.timeIntervalSince(t.transitionDate) / (24 * 60 * 60)
                        if days > 0 { applicantDays.append(days) }
                    }
                }
            }
        }

        return TimeInStageMetrics(
            avgDaysAsLead: leadDays.isEmpty ? 0 : leadDays.reduce(0, +) / Double(leadDays.count),
            avgDaysAsApplicant: applicantDays.isEmpty ? 0 : applicantDays.reduce(0, +) / Double(applicantDays.count)
        )
    }

    // MARK: - Recruiting Pipeline

    private func refreshRecruitingPipeline() {
        do {
            let allStages = try PipelineRepository.shared.fetchAllRecruitingStages()

            // Funnel counts grouped by stage
            var counts: [RecruitingStageKind: Int] = [:]
            for record in allStages {
                counts[record.stage, default: 0] += 1
            }
            recruitFunnel = RecruitingStageKind.allCases.map { kind in
                RecruitingStageSummary(stage: kind, count: counts[kind] ?? 0)
            }

            // Licensing rate: (Licensed + FirstSale + Producing) / total
            let total = allStages.count
            let licensed = allStages.filter {
                $0.stage.order >= RecruitingStageKind.licensed.order
            }.count
            recruitLicensingRate = total > 0 ? Double(licensed) / Double(total) : 0

            // Mentoring alerts
            let now = Date.now
            var alerts: [MentoringAlert] = []
            for record in allStages {
                let threshold: TimeInterval
                switch record.stage {
                case .studying:  threshold = 7 * 24 * 60 * 60
                case .licensed:  threshold = 14 * 24 * 60 * 60
                case .producing: threshold = 30 * 24 * 60 * 60
                default: continue
                }

                let lastContact = record.mentoringLastContact ?? record.enteredDate
                let gap = now.timeIntervalSince(lastContact)
                if gap >= threshold {
                    alerts.append(MentoringAlert(
                        personID: record.person?.id ?? UUID(),
                        personName: record.person?.displayNameCache
                            ?? record.person?.displayName ?? "Unknown",
                        stage: record.stage,
                        daysSinceContact: Int(gap / (24 * 60 * 60))
                    ))
                }
            }

            recruitMentoringAlerts = alerts.sorted { $0.daysSinceContact > $1.daysSinceContact }

        } catch {
            logger.error("Failed to refresh recruiting pipeline: \(error)")
        }
    }

    // MARK: - Production

    private func refreshProduction() {
        do {
            let windowStart = Calendar.current.date(
                byAdding: .day, value: -productionWindowDays, to: .now
            ) ?? .now
            let windowRecords = try ProductionRepository.shared.fetchRecords(since: windowStart)

            // By status
            var statusMap: [ProductionStatus: (count: Int, premium: Double)] = [:]
            for record in windowRecords {
                var entry = statusMap[record.status] ?? (count: 0, premium: 0)
                entry.count += 1
                entry.premium += record.annualPremium
                statusMap[record.status] = entry
            }
            productionByStatus = ProductionStatus.allCases.map { status in
                let data = statusMap[status] ?? (count: 0, premium: 0)
                return ProductionStatusSummary(
                    status: status,
                    count: data.count,
                    totalPremium: data.premium
                )
            }

            // By product type
            var typeMap: [WFGProductType: (count: Int, premium: Double)] = [:]
            for record in windowRecords {
                var entry = typeMap[record.productType] ?? (count: 0, premium: 0)
                entry.count += 1
                entry.premium += record.annualPremium
                typeMap[record.productType] = entry
            }
            productionByType = WFGProductType.allCases.compactMap { type in
                guard let data = typeMap[type] else { return nil }
                return ProductionTypeSummary(
                    productType: type,
                    count: data.count,
                    totalPremium: data.premium
                )
            }

            // Totals
            productionTotalPremium = windowRecords.reduce(0) { $0 + $1.annualPremium }
            productionPendingCount = windowRecords.filter { $0.status == .submitted }.count

            // Pending aging
            let allPending = try ProductionRepository.shared.pendingWithAge()
            productionPendingAging = allPending.map { item in
                PendingAgingItem(
                    recordID: item.record.id,
                    personID: item.record.person?.id,
                    personName: item.record.person?.displayNameCache
                        ?? item.record.person?.displayName ?? "Unknown",
                    productType: item.record.productType,
                    carrierName: item.record.carrierName,
                    daysPending: item.daysPending,
                    premium: item.record.annualPremium
                )
            }

            // All records in window (for master list)
            productionAllRecords = windowRecords.map { record in
                ProductionRecordItem(
                    recordID: record.id,
                    personID: record.person?.id,
                    personName: record.person?.displayNameCache
                        ?? record.person?.displayName ?? "Unknown",
                    productType: record.productType,
                    status: record.status,
                    carrierName: record.carrierName,
                    annualPremium: record.annualPremium,
                    submittedDate: record.submittedDate,
                    resolvedDate: record.resolvedDate
                )
            }

        } catch {
            logger.error("Failed to refresh production metrics: \(error)")
        }
    }
}

// MARK: - Value Types

extension PipelineTracker {

    struct FunnelSnapshot {
        var leadCount: Int = 0
        var applicantCount: Int = 0
        var clientCount: Int = 0

        var total: Int { leadCount + applicantCount + clientCount }
    }

    struct ConversionRates {
        var leadToApplicant: Double = 0
        var applicantToClient: Double = 0
    }

    struct TimeInStageMetrics {
        var avgDaysAsLead: Double = 0
        var avgDaysAsApplicant: Double = 0
    }

    struct StuckPerson: Identifiable {
        let personID: UUID
        let personName: String
        let stage: String
        let daysStuck: Int

        var id: UUID { personID }
    }

    struct RecruitingStageSummary: Identifiable {
        let stage: RecruitingStageKind
        let count: Int

        var id: String { stage.rawValue }
    }

    struct MentoringAlert: Identifiable {
        let personID: UUID
        let personName: String
        let stage: RecruitingStageKind
        let daysSinceContact: Int

        var id: UUID { personID }
    }

    struct RecentTransition: Identifiable {
        let id: UUID
        let personName: String
        let personID: UUID?
        let fromStage: String
        let toStage: String
        let date: Date
    }

    // Phase S: Production value types

    struct ProductionStatusSummary: Identifiable {
        let status: ProductionStatus
        let count: Int
        let totalPremium: Double

        var id: String { status.rawValue }
    }

    struct ProductionTypeSummary: Identifiable {
        let productType: WFGProductType
        let count: Int
        let totalPremium: Double

        var id: String { productType.rawValue }
    }

    struct PendingAgingItem: Identifiable {
        let recordID: UUID
        let personID: UUID?
        let personName: String
        let productType: WFGProductType
        let carrierName: String
        let daysPending: Int
        let premium: Double

        var id: UUID { recordID }
    }

    struct ProductionRecordItem: Identifiable {
        let recordID: UUID
        let personID: UUID?
        let personName: String
        let productType: WFGProductType
        let status: ProductionStatus
        let carrierName: String
        let annualPremium: Double
        let submittedDate: Date
        let resolvedDate: Date?

        var id: UUID { recordID }
    }
}
