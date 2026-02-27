//
//  CommandPaletteView.swift
//  SAM
//
//  Created on February 27, 2026.
//  ⌘K Command Palette — Spotlight-style quick navigation and search.
//
//  Fuzzy-searches static navigation commands and actions, plus people
//  via the existing SearchCoordinator. Presented as a sheet from AppShellView.
//

import SwiftUI
import SwiftData

struct CommandPaletteView: View {

    let onNavigate: (String) -> Void
    let onSelectPerson: (UUID) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var coordinator = SearchCoordinator()
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedIndex: Int = 0
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search commands and people\u{2026}", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit {
                        executeSelected()
                    }

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Results list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let items = filteredItems
                        if items.isEmpty && !query.isEmpty {
                            Text("No results")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        } else {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                paletteRow(item: item, isSelected: index == selectedIndex)
                                    .id(index)
                                    .onTapGesture {
                                        selectedIndex = index
                                        executeSelected()
                                    }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 320)
                .onChange(of: selectedIndex) { _, newIndex in
                    withAnimation {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear {
            if let container = modelContext.container as ModelContainer? {
                coordinator.configure(container: container)
            }
        }
        .onChange(of: query) { _, newValue in
            selectedIndex = 0
            searchTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                coordinator.searchText = ""
                coordinator.clearResults()
            } else {
                coordinator.searchText = trimmed
                coordinator.scope = .people
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    coordinator.performSearch()
                }
            }
        }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 { selectedIndex -= 1 }
            return .handled
        }
        .onKeyPress(.downArrow) {
            let count = filteredItems.count
            if selectedIndex < count - 1 { selectedIndex += 1 }
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    // MARK: - Palette Items

    private var filteredItems: [PaletteItem] {
        let lowered = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        var results: [PaletteItem] = []

        // Static commands — filtered by fuzzy substring match
        let commands = Self.staticCommands
        if lowered.isEmpty {
            results.append(contentsOf: commands)
        } else {
            results.append(contentsOf: commands.filter {
                $0.label.lowercased().contains(lowered)
            })
        }

        // People results from SearchCoordinator (limit to 5)
        if !lowered.isEmpty {
            let people = Array(coordinator.peopleResults.prefix(5))
            results.append(contentsOf: people.map { .person($0) })
        }

        return results
    }

    private static let staticCommands: [PaletteItem] = [
        .navigation(id: "nav-today", label: "Go to Today", icon: "sun.max", shortcut: "\u{2318}1", section: "today"),
        .navigation(id: "nav-people", label: "Go to People", icon: "person.2", shortcut: "\u{2318}2", section: "people"),
        .navigation(id: "nav-business", label: "Go to Business", icon: "chart.bar.horizontal.page", shortcut: "\u{2318}3", section: "business"),
        .navigation(id: "nav-search", label: "Go to Search", icon: "magnifyingglass", shortcut: "\u{2318}4", section: "search"),
        .action(id: "act-note", label: "New Note", icon: "square.and.pencil", shortcut: "\u{2318}N"),
        .action(id: "act-settings", label: "Open Settings", icon: "gearshape", shortcut: "\u{2318},"),
    ]

    // MARK: - Row View

    @ViewBuilder
    private func paletteRow(item: PaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            switch item {
            case .navigation(_, let label, let icon, let shortcut, _):
                Image(systemName: icon)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.body)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

            case .action(_, let label, let icon, let shortcut):
                Image(systemName: icon)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.body)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

            case .person(let person):
                if let photoData = person.photoThumbnailCache,
                   let nsImage = NSImage(data: photoData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 22, height: 22)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .frame(width: 22, height: 22)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(person.displayNameCache ?? person.displayName)
                        .font(.body)
                        .lineLimit(1)
                    if let email = person.emailCache ?? person.email {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                ForEach(person.roleBadges, id: \.self) { badge in
                    RoleBadgeIconView(badge: badge)
                }

                Spacer()

                Text("Person")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
    }

    // MARK: - Execution

    private func executeSelected() {
        let items = filteredItems
        guard selectedIndex >= 0 && selectedIndex < items.count else { return }

        let item = items[selectedIndex]
        switch item {
        case .navigation(_, _, _, _, let section):
            onNavigate(section)
            onDismiss()

        case .action(let id, _, _, _):
            switch id {
            case "act-note":
                let payload = QuickNotePayload(
                    outcomeID: UUID(),
                    personID: nil,
                    personName: nil,
                    contextTitle: "Quick Note"
                )
                NotificationCenter.default.post(
                    name: .samOpenQuickNote,
                    object: nil,
                    userInfo: ["payload": payload]
                )
            case "act-settings":
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            default:
                break
            }
            onDismiss()

        case .person(let person):
            onSelectPerson(person.id)
            onDismiss()
        }
    }
}

// MARK: - Palette Item

private enum PaletteItem: Identifiable {
    case navigation(id: String, label: String, icon: String, shortcut: String?, section: String)
    case action(id: String, label: String, icon: String, shortcut: String?)
    case person(SamPerson)

    var id: String {
        switch self {
        case .navigation(let id, _, _, _, _): return id
        case .action(let id, _, _, _): return id
        case .person(let person): return person.id.uuidString
        }
    }

    var label: String {
        switch self {
        case .navigation(_, let label, _, _, _): return label
        case .action(_, let label, _, _): return label
        case .person(let person): return person.displayNameCache ?? person.displayName
        }
    }
}
