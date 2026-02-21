//
//  PeopleListView.swift
//  SAM_crm
//
//  Created on February 10, 2026.
//  Phase D: First Feature - People
//
//  List view for all people in SAM.
//  Displays contacts from PeopleRepository with search and filtering.
//

import SwiftUI
import SwiftData

struct PeopleListView: View {
    
    // MARK: - Bindings
    
    @Binding var selectedPersonID: UUID?
    
    // MARK: - Dependencies
    
    @State private var repository = PeopleRepository.shared
    @State private var importCoordinator = ContactsImportCoordinator.shared
    
    // MARK: - State
    
    @State private var people: [SamPerson] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    // MARK: - Body
    
    var body: some View {
        Group {
            if isLoading && people.isEmpty {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else if people.isEmpty {
                emptyView
            } else {
                peopleList
            }
        }
        .navigationTitle("People")
        .searchable(text: $searchText, prompt: "Search people")
        .toolbar {
            ToolbarItemGroup {
                importStatusBadge
                
                Button {
                    Task {
                        await importCoordinator.importNow()
                        await loadPeople()
                    }
                } label: {
                    Label("Import Now", systemImage: "arrow.clockwise")
                }
                .disabled(importCoordinator.importStatus == .importing)
                .help("Import contacts from Apple Contacts")
            }
        }
        .task {
            await loadPeople()
        }
        .onChange(of: searchText) { _, _ in
            Task {
                await searchPeople()
            }
        }
    }
    
    // MARK: - People List
    
    private var peopleList: some View {
        List(selection: $selectedPersonID) {
            ForEach(people, id: \.id) { person in
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
                    await loadPeople()
                }
            } label: {
                Text("Import Now")
            }
            .buttonStyle(.borderedProminent)
        }
    }
    
    // MARK: - Loading State
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading people...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Error State
    
    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Error", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                Task {
                    await loadPeople()
                }
            }
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
    
    // MARK: - Data Operations
    
    private func loadPeople() async {
        isLoading = true
        errorMessage = nil
        
        do {
            people = try repository.fetchAll()
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
    
    private func searchPeople() async {
        guard !searchText.isEmpty else {
            await loadPeople()
            return
        }
        
        do {
            people = try repository.search(query: searchText)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Person Row View

private struct PersonRowView: View {
    let person: SamPerson
    
    var body: some View {
        HStack(spacing: 12) {
            // Photo thumbnail
            if let photoData = person.photoThumbnailCache,
               let nsImage = NSImage(data: photoData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.secondary)
            }
            
            // Name and email
            VStack(alignment: .leading, spacing: 2) {
                Text(person.displayNameCache ?? person.displayName)
                    .font(.body)
                
                if let email = person.emailCache ?? person.email {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            // Badges and alerts
            HStack(spacing: 8) {
                // Role badges
                if !person.roleBadges.isEmpty {
                    ForEach(person.roleBadges, id: \.self) { badge in
                        Text(badge)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.2))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                }
                
                // Not in Contacts badge (clickable — adds to Apple Contacts)
                NotInContactsCapsule(person: person)

                // Consent alerts
                if person.consentAlertsCount > 0 {
                    Label("\(person.consentAlertsCount)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                
                // Review alerts
                if person.reviewAlertsCount > 0 {
                    Label("\(person.reviewAlertsCount)", systemImage: "bell.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
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
    
    // Add sample data
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
