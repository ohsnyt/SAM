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

    var configWindowDays: Int = 90

    // MARK: - Refresh

    func refresh() {
        refreshClientPipeline()
        refreshRecruitingPipeline()
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
}
