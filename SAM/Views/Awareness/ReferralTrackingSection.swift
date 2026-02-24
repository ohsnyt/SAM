//
//  ReferralTrackingSection.swift
//  SAM
//
//  Created on February 24, 2026.
//  Referral Tracking — surfaces top referral sources and referral opportunities.
//
//  Supports WFG referral-driven growth model by highlighting who refers
//  the most contacts and which long-term clients haven't referred anyone yet.
//

import SwiftUI
import SwiftData

struct ReferralTrackingSection: View {

    @Query(filter: #Predicate<SamPerson> { !$0.isMe && !$0.isArchived })
    private var people: [SamPerson]

    @State private var showTopReferrers = true
    @State private var showOpportunities = true

    // MARK: - Stub Data Computation

    // TODO: Wire to SamPerson.referredBy once schema is updated
    // TODO: Wire to SamPerson.referrals once schema is updated
    /// Returns people sorted by how many others they have referred (descending), top 5.
    private var topReferrers: [ReferrerEntry] {
        // TODO: Wire to SamPerson.referrals once schema is updated
        // Real implementation will be:
        //   people
        //     .compactMap { person -> ReferrerEntry? in
        //         let count = person.referrals.count
        //         guard count > 0 else { return nil }
        //         return ReferrerEntry(
        //             personID: person.id,
        //             displayName: person.displayNameCache ?? person.displayName,
        //             roleBadges: person.roleBadges,
        //             referralCount: count
        //         )
        //     }
        //     .sorted { $0.referralCount > $1.referralCount }
        //     .prefix(5)
        //     .map { $0 }
        return []
    }

    /// Clients with 6+ months of relationship history who haven't referred anyone.
    private var referralOpportunities: [OpportunityEntry] {
        // TODO: Wire to SamPerson.referrals once schema is updated
        // Real implementation will be:
        //   let sixMonthsAgo = Calendar.current.date(byAdding: .month, value: -6, to: .now) ?? .now
        //   return people
        //     .filter { person in
        //         person.roleBadges.contains("Client")
        //         && person.referrals.isEmpty
        //         && earliestEvidenceDate(for: person).map { $0 <= sixMonthsAgo } == true
        //     }
        //     .compactMap { person in
        //         guard let earliest = earliestEvidenceDate(for: person) else { return nil }
        //         let months = Calendar.current.dateComponents([.month], from: earliest, to: .now).month ?? 0
        //         return OpportunityEntry(
        //             personID: person.id,
        //             displayName: person.displayNameCache ?? person.displayName,
        //             roleBadges: person.roleBadges,
        //             relationshipMonths: months
        //         )
        //     }
        //     .sorted { $0.relationshipMonths > $1.relationshipMonths }
        let sixMonthsAgo = Calendar.current.date(byAdding: .month, value: -6, to: .now) ?? .now

        return people
            .filter { person in
                person.roleBadges.contains("Client")
                && earliestEvidenceDate(for: person).map { $0 <= sixMonthsAgo } == true
            }
            .compactMap { person in
                guard let earliest = earliestEvidenceDate(for: person) else { return nil }
                let months = Calendar.current.dateComponents([.month], from: earliest, to: .now).month ?? 0
                return OpportunityEntry(
                    personID: person.id,
                    displayName: person.displayNameCache ?? person.displayName,
                    roleBadges: person.roleBadges,
                    relationshipMonths: months
                )
            }
            .sorted { $0.relationshipMonths > $1.relationshipMonths }
    }

    private var totalReferralCount: Int {
        // TODO: Wire to SamPerson.referredBy once schema is updated
        // Real implementation: people.filter { $0.referredBy != nil }.count
        0
    }

    private var hasAnyReferralData: Bool {
        // TODO: Wire to SamPerson.referredBy once schema is updated
        // Real implementation: people.contains { $0.referredBy != nil }
        false
    }

    // MARK: - Body

    var body: some View {
        let referrers = topReferrers
        let opportunities = referralOpportunities

        VStack(spacing: 0) {
            // Section header
            HStack {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.green)
                Text("Referrals")
                    .font(.headline)
                if totalReferralCount > 0 {
                    Text("\(totalReferralCount)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green)
                        .clipShape(Capsule())
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            if !hasAnyReferralData && opportunities.isEmpty {
                // Empty state — no referral data tracked yet
                emptyState
                    .padding()
            } else {
                VStack(spacing: 0) {
                    // Top Referrers sub-section
                    if !referrers.isEmpty {
                        topReferrersSection(referrers)
                    }

                    // Referral Opportunities sub-section
                    if !opportunities.isEmpty {
                        if !referrers.isEmpty {
                            Divider()
                                .padding(.horizontal)
                        }
                        opportunitiesSection(opportunities)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No referral data yet")
                .font(.subheadline)
                .fontWeight(.medium)
            Text("Track who referred each contact to surface your best referral sources. Set referrals from each person's detail page.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Top Referrers

    private func topReferrersSection(_ referrers: [ReferrerEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation { showTopReferrers.toggle() } }) {
                HStack {
                    Image(systemName: showTopReferrers ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("Top Referrers (\(referrers.count))")
                        .font(.caption)
                        .fontWeight(.medium)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if showTopReferrers {
                VStack(spacing: 8) {
                    ForEach(referrers) { entry in
                        ReferrerRow(entry: entry)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
        }
    }

    // MARK: - Referral Opportunities

    private func opportunitiesSection(_ opportunities: [OpportunityEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation { showOpportunities.toggle() } }) {
                HStack {
                    Image(systemName: showOpportunities ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("Referral Opportunities (\(opportunities.count))")
                        .font(.caption)
                        .fontWeight(.medium)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if showOpportunities {
                VStack(spacing: 8) {
                    ForEach(opportunities) { entry in
                        OpportunityRow(entry: entry)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
        }
    }

    // MARK: - Helpers

    private func earliestEvidenceDate(for person: SamPerson) -> Date? {
        person.linkedEvidence
            .map(\.occurredAt)
            .min()
    }
}

// MARK: - Data Types

private struct ReferrerEntry: Identifiable {
    let personID: UUID
    let displayName: String
    let roleBadges: [String]
    let referralCount: Int

    var id: UUID { personID }
}

private struct OpportunityEntry: Identifiable {
    let personID: UUID
    let displayName: String
    let roleBadges: [String]
    let relationshipMonths: Int

    var id: UUID { personID }

    var relationshipLabel: String {
        if relationshipMonths >= 12 {
            let years = relationshipMonths / 12
            let remaining = relationshipMonths % 12
            if remaining == 0 {
                return years == 1 ? "1 year" : "\(years) years"
            }
            return "\(years)y \(remaining)m"
        }
        return "\(relationshipMonths) months"
    }
}

// MARK: - Referrer Row

private struct ReferrerRow: View {

    let entry: ReferrerEntry

    var body: some View {
        Button(action: navigateToPerson) {
            HStack(spacing: 12) {
                // Rank indicator
                Image(systemName: "person.2.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.displayName)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)

                        ForEach(entry.roleBadges.prefix(2), id: \.self) { badge in
                            let style = RoleBadgeStyle.forBadge(badge)
                            Text(badge)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(style.color.opacity(0.15))
                                .foregroundStyle(style.color)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }
                }

                Spacer()

                // Referral count badge
                Text("\(entry.referralCount) referral\(entry.referralCount == 1 ? "" : "s")")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.green)
            }
            .padding(10)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func navigateToPerson() {
        NotificationCenter.default.post(
            name: .samNavigateToPerson,
            object: nil,
            userInfo: ["personID": entry.personID]
        )
    }
}

// MARK: - Opportunity Row

private struct OpportunityRow: View {

    let entry: OpportunityEntry

    var body: some View {
        Button(action: navigateToPerson) {
            HStack(spacing: 12) {
                // Opportunity indicator
                Image(systemName: "lightbulb.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.displayName)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)

                        ForEach(entry.roleBadges.prefix(2), id: \.self) { badge in
                            let style = RoleBadgeStyle.forBadge(badge)
                            Text(badge)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(style.color.opacity(0.15))
                                .foregroundStyle(style.color)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }

                    Text("Client for \(entry.relationshipLabel) · No referrals yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("Consider asking")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .padding(10)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func navigateToPerson() {
        NotificationCenter.default.post(
            name: .samNavigateToPerson,
            object: nil,
            userInfo: ["personID": entry.personID]
        )
    }
}
