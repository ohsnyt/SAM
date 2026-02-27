//
//  GhostMergePersonPicker.swift
//  SAM
//
//  Created on February 26, 2026.
//  Ghost Node → Existing Contact Merge
//
//  Searchable person picker sheet for linking a ghost mention
//  to an existing known contact.
//

import SwiftUI
import SwiftData

struct GhostMergePersonPicker: View {

    let ghostName: String
    let onSelect: (SamPerson) -> Void
    let onCancel: () -> Void

    @Query(
        filter: #Predicate<SamPerson> { !$0.isMe && !$0.isArchived },
        sort: \SamPerson.displayNameCache
    )
    private var allPeople: [SamPerson]

    @State private var searchText: String = ""

    private var filteredPeople: [SamPerson] {
        guard !searchText.isEmpty else { return allPeople }
        let query = searchText.lowercased()
        return allPeople.filter {
            ($0.displayNameCache ?? $0.displayName).lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchField
            personList
        }
        .frame(width: 360, height: 440)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Link to Existing Contact")
                    .font(.headline)
                Text("Link \"\(ghostName)\" mentions to:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { onCancel() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("Search contacts…", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - List

    private var personList: some View {
        List {
            ForEach(filteredPeople) { person in
                Button {
                    onSelect(person)
                } label: {
                    personRow(person)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .overlay {
            if filteredPeople.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    // MARK: - Row

    private func personRow(_ person: SamPerson) -> some View {
        HStack(spacing: 10) {
            initialsCircle(person)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.displayNameCache ?? person.displayName)
                    .font(.body)
                if !person.roleBadges.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(person.roleBadges.prefix(3), id: \.self) { badge in
                            let style = RoleBadgeStyle.forBadge(badge)
                            Label(badge, systemImage: style.icon)
                                .font(.caption2)
                                .foregroundStyle(style.color)
                        }
                    }
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private func initialsCircle(_ person: SamPerson) -> some View {
        let name = person.displayNameCache ?? person.displayName
        let initials = name.split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()

        return Circle()
            .fill(Color.accentColor.opacity(0.15))
            .frame(width: 32, height: 32)
            .overlay {
                Text(initials.isEmpty ? "?" : initials)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }
    }
}
