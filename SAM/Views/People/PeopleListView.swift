//
//  PeopleListView.swift
//  SAM_crm
//
//  Created on February 10, 2026.
//  Phase D: First Feature - People
//
//  List view for all people in SAM.
//  Displays contacts from PeopleRepository with search, sorting, and role filtering.
//

import SwiftUI
import SwiftData
import TipKit

// MARK: - Sort & Filter Types

enum PeopleSortOrder: String, CaseIterable, Identifiable {
    case firstName = "First Name"
    case lastName = "Last Name"
    case email = "Email"
    case health = "Relationship Health"

    var id: String { rawValue }
}

struct PeopleListView: View {

    // MARK: - Bindings

    @Binding var selectedPersonID: UUID?

    // MARK: - Dependencies

    @Query(sort: \SamPerson.displayNameCache) private var allPeople: [SamPerson]
    @State private var importCoordinator = ContactsImportCoordinator.shared

    // MARK: - State

    @State private var searchText = ""
    @State private var sortOrder: PeopleSortOrder = .firstName
    @State private var activeRoleFilters: Set<String> = []

    // MARK: - Computed

    /// All roles present across all people (unfiltered), for the filter menu.
    private var availableRoles: [String] {
        let allRoles = allPeople.flatMap(\.roleBadges)
        let predefined = ["Client", "Applicant", "Lead", "Vendor", "Agent", "External Agent", "Referral Partner"]
        var seen = Set<String>()
        var result: [String] = []
        for role in predefined where allRoles.contains(role) {
            if seen.insert(role).inserted { result.append(role) }
        }
        for role in allRoles.sorted() {
            if seen.insert(role).inserted { result.append(role) }
        }
        return result
    }

    /// People after search, role filter, and sort.
    private var displayedPeople: [SamPerson] {
        var list = Array(allPeople)

        // Search
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            list = list.filter { person in
                let name = person.displayNameCache ?? person.displayName
                if name.lowercased().contains(query) { return true }
                if let email = person.emailCache ?? person.email,
                   email.lowercased().contains(query) { return true }
                return false
            }
        }

        // Role filter
        if !activeRoleFilters.isEmpty {
            list = list.filter { person in
                !activeRoleFilters.isDisjoint(with: person.roleBadges)
            }
        }

        // Sort
        list.sort { a, b in
            let nameA = a.displayNameCache ?? a.displayName
            let nameB = b.displayNameCache ?? b.displayName
            switch sortOrder {
            case .firstName:
                return nameA.localizedCaseInsensitiveCompare(nameB) == .orderedAscending
            case .lastName:
                return lastNameSort(nameA).localizedCaseInsensitiveCompare(lastNameSort(nameB)) == .orderedAscending
            case .email:
                let emailA = a.emailCache ?? a.email ?? ""
                let emailB = b.emailCache ?? b.email ?? ""
                if emailA.isEmpty && emailB.isEmpty {
                    return nameA.localizedCaseInsensitiveCompare(nameB) == .orderedAscending
                }
                if emailA.isEmpty { return false }
                if emailB.isEmpty { return true }
                return emailA.localizedCaseInsensitiveCompare(emailB) == .orderedAscending
            case .health:
                let scoreA = healthSortScore(a)
                let scoreB = healthSortScore(b)
                if scoreA != scoreB { return scoreA > scoreB }
                // Tie-break by name
                return nameA.localizedCaseInsensitiveCompare(nameB) == .orderedAscending
            }
        }

        return list
    }

    /// Extract "LastName, FirstName..." style key for last-name sorting.
    private func lastNameSort(_ fullName: String) -> String {
        let parts = fullName.split(separator: " ")
        guard parts.count > 1 else { return fullName }
        let last = parts.last!
        let rest = parts.dropLast().joined(separator: " ")
        return "\(last) \(rest)"
    }

    /// Numeric health urgency score: higher = needs attention sooner.
    /// No interactions / Me = -1 (bottom). Healthy = 1+. At risk = 3+.
    private func healthSortScore(_ person: SamPerson) -> Double {
        guard !person.isMe, !person.linkedEvidence.isEmpty else { return -1 }
        let health = MeetingPrepCoordinator.shared.computeHealth(for: person)
        // Base score from decay risk: healthy people get 1-2, at-risk get 3-5
        let riskScore: Double
        switch health.decayRisk {
        case .none:     riskScore = 1
        case .low:      riskScore = 2
        case .moderate: riskScore = 3
        case .high:     riskScore = 4
        case .critical: riskScore = 5
        }
        // Add fractional overdue ratio for finer ordering within same risk tier
        let overdue = min(health.overdueRatio ?? 0, 10)
        return riskScore + (overdue / 20)
    }

    // MARK: - Body

    var body: some View {
        peopleList
            .overlay {
                if allPeople.isEmpty {
                    emptyView
                } else if displayedPeople.isEmpty {
                    noMatchView
                }
            }
            .navigationTitle("People")
        .popoverTip(PeopleListTip(), arrowEdge: .top)
        .searchable(text: $searchText, prompt: "Search people")
        .toolbar {
            ToolbarItemGroup {
                // Sort picker
                Menu {
                    ForEach(PeopleSortOrder.allCases) { order in
                        Button {
                            sortOrder = order
                        } label: {
                            HStack {
                                Text(order.rawValue)
                                if sortOrder == order {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort people")

                // Role filter
                Menu {
                    if !activeRoleFilters.isEmpty {
                        Button("Clear Filters") {
                            activeRoleFilters.removeAll()
                        }
                        Divider()
                    }
                    ForEach(availableRoles, id: \.self) { role in
                        let isSelected = activeRoleFilters.contains(role)
                        Button {
                            if isSelected {
                                activeRoleFilters.remove(role)
                            } else {
                                activeRoleFilters.insert(role)
                            }
                        } label: {
                            HStack {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected
                                        ? RoleBadgeStyle.forBadge(role).color
                                        : .secondary)
                                Image(systemName: RoleBadgeStyle.forBadge(role).icon)
                                    .foregroundStyle(RoleBadgeStyle.forBadge(role).color)
                                Text(role)
                            }
                        }
                    }
                    if availableRoles.isEmpty {
                        Text("No roles assigned yet")
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Label("Filter", systemImage: activeRoleFilters.isEmpty
                          ? "line.3.horizontal.decrease"
                          : "line.3.horizontal.decrease.circle.fill")
                }
                .help(activeRoleFilters.isEmpty ? "Filter by role" : "Filtering by \(activeRoleFilters.count) role\(activeRoleFilters.count == 1 ? "" : "s")")

                importStatusBadge

                Button {
                    Task {
                        await importCoordinator.importNow()
                    }
                } label: {
                    Label("Import Now", systemImage: "arrow.clockwise")
                }
                .disabled(importCoordinator.importStatus == .importing)
                .help("Import contacts from Apple Contacts")
            }
        }
    }

    // MARK: - People List

    private var peopleList: some View {
        List(selection: $selectedPersonID) {
            // Active filter summary
            if !activeRoleFilters.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(activeRoleFilters).sorted(), id: \.self) { role in
                        let style = RoleBadgeStyle.forBadge(role)
                        HStack(spacing: 3) {
                            Image(systemName: style.icon)
                                .font(.system(size: 10))
                            Text(role)
                                .font(.caption2)
                        }
                        .foregroundStyle(style.color)
                    }
                    Spacer()
                    Text("\(displayedPeople.count) of \(allPeople.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .listRowSeparator(.hidden)
            }

            ForEach(displayedPeople, id: \.id) { person in
                Button(action: {
                    selectedPersonID = person.id
                }) {
                    PersonRowView(person: person)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - No Match State

    private var noMatchView: some View {
        ContentUnavailableView {
            Label("No Matches", systemImage: "person.2.slash")
        } description: {
            if !searchText.isEmpty && !activeRoleFilters.isEmpty {
                Text("No people match your search and filters")
            } else if !searchText.isEmpty {
                Text("No people match \"\(searchText)\"")
            } else {
                Text("No people match the current filters")
            }
        } actions: {
            if !activeRoleFilters.isEmpty {
                Button("Clear Filters") {
                    activeRoleFilters.removeAll()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Empty State

    private var emptyView: some View {
        ContentUnavailableView {
            Label("No People", systemImage: "person.2.slash")
        } description: {
            Text("Import contacts from Apple Contacts to get started")
        } actions: {
            Button {
                Task {
                    await importCoordinator.importNow()
                }
            } label: {
                Text("Import Now")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Import Status Badge

    @ViewBuilder
    private var importStatusBadge: some View {
        if importCoordinator.importStatus == .importing {
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Importing...")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        } else if let date = importCoordinator.lastImportedAt {
            Text("\(importCoordinator.lastImportCount) contacts, \(date, style: .relative) ago")
                .font(.caption)
                .foregroundStyle(importCoordinator.importStatus == .failed ? .red : .green)
        }
    }
}

// MARK: - Person Row View

private struct PersonRowView: View {
    let person: SamPerson

    // Cached health computation — avoids redundant calls per render
    private var health: RelationshipHealth? {
        guard !person.isMe else { return nil }
        return MeetingPrepCoordinator.shared.computeHealth(for: person)
    }

    /// Coaching preview text for at-risk contacts.
    private var coachingPreview: String? {
        guard let h = health else { return nil }

        // Priority 1: High/critical decay → follow up prompt
        if h.decayRisk >= .high, let days = h.daysSinceLastInteraction {
            return "Follow up — \(days) days since last contact"
        }

        // Priority 2: Decelerating velocity
        if h.velocityTrend == .decelerating {
            return "Engagement slowing"
        }

        return nil
    }

    /// Urgency strip color for leading edge accent.
    private var urgencyStripColor: Color? {
        guard let h = health else { return nil }
        switch h.decayRisk {
        case .critical: return .red
        case .high:     return .orange
        default:        return nil
        }
    }

    /// Initials derived from the person's name (max 2 characters).
    private var initials: String {
        let name = person.displayNameCache ?? person.displayName
        let words = name.split(separator: " ")
        let chars = words.prefix(2).compactMap(\.first)
        return String(chars).uppercased()
    }

    /// Color for the initials circle, based on primary role.
    private var initialsColor: Color {
        if let primaryRole = person.roleBadges.first {
            return RoleBadgeStyle.forBadge(primaryRole).color
        }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 0) {
            // Urgency accent strip on leading edge
            if let stripColor = urgencyStripColor {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(stripColor)
                    .frame(width: 3, height: 36)
                    .padding(.trailing, 6)
            }

            HStack(spacing: 8) {
                // Photo thumbnail or initials fallback
                if let photoData = person.photoThumbnailCache,
                   let nsImage = NSImage(data: photoData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                } else {
                    ZStack {
                        Circle()
                            .fill(initialsColor.opacity(0.15))
                            .frame(width: 32, height: 32)
                        Text(initials)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(initialsColor)
                    }
                }

                // Name, coaching preview, role badges
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(person.displayNameCache ?? person.displayName)
                            .font(.headline)

                        if person.isMe {
                            Text("Me")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.secondary)
                                .clipShape(Capsule())
                        }

                        // Role badge icons after name
                        ForEach(person.roleBadges, id: \.self) { badge in
                            RoleBadgeIconView(badge: badge)
                        }
                    }

                    if let preview = coachingPreview {
                        Text(preview)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if let email = person.emailCache ?? person.email {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Trailing badges and alerts
                HStack(spacing: 8) {
                    NotInContactsCapsule(person: person)

                    if person.consentAlertsCount > 0 {
                        Label("\(person.consentAlertsCount)", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if person.reviewAlertsCount > 0 {
                        Label("\(person.reviewAlertsCount)", systemImage: "bell.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview("With People") {
    let container = SAMModelContainer.shared
    PeopleRepository.shared.configure(container: container)

    let context = ModelContext(container)

    let person1 = SamPerson(
        id: UUID(),
        displayName: "John Doe",
        roleBadges: ["Client"],
        contactIdentifier: "1",
        email: "john@example.com",
        reviewAlertsCount: 2
    )
    person1.displayNameCache = "John Doe"
    person1.emailCache = "john@example.com"

    let person2 = SamPerson(
        id: UUID(),
        displayName: "Jane Smith",
        roleBadges: ["Referral Partner"],
        contactIdentifier: "2",
        email: "jane@example.com"
    )
    person2.displayNameCache = "Jane Smith"
    person2.emailCache = "jane@example.com"

    context.insert(person1)
    context.insert(person2)
    try? context.save()

    return NavigationStack {
        PeopleListView(selectedPersonID: .constant(nil))
            .modelContainer(container)
    }
    .frame(width: 400, height: 600)
}

#Preview("Empty") {
    let container = SAMModelContainer.shared
    PeopleRepository.shared.configure(container: container)

    return NavigationStack {
        PeopleListView(selectedPersonID: .constant(nil))
            .modelContainer(container)
    }
    .frame(width: 400, height: 600)
}
