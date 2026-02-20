//
//  ContextDetailView.swift
//  SAM_crm
//
//  Created by Assistant on 2/11/26.
//  Phase G: Contexts
//
//  Detail view for a selected context (household, business, etc.).
//  Shows participants, products, and other context information.
//

import SwiftUI
import SwiftData

struct ContextDetailView: View {
    let context: SamContext
    
    @State private var showingEditSheet = false
    @State private var showingAddParticipantSheet = false
    @State private var showingDeleteConfirmation = false
    @State private var repository = NotesRepository.shared
    @State private var contextNotes: [SamNote] = []
    @State private var editingNote: SamNote?
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                header
                
                Divider()
                
                // Participants section
                if !context.participations.isEmpty {
                    participantsSection
                    Divider()
                }
                
                // Products section (placeholder)
                if !context.productCards.isEmpty {
                    productsSection
                    Divider()
                }
                
                // Insights section (placeholder)
                if !context.insights.isEmpty {
                    insightsSection
                    Divider()
                }
                
                // Notes section (Phase H)
                notesSection
                Divider()
                
                // Metadata section
                metadataSection
            }
            .padding()
        }
        .navigationTitle(context.name)
        .navigationSubtitle(context.kind.displayName)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showingAddParticipantSheet = true
                } label: {
                    Label("Add Person", systemImage: "person.badge.plus")
                }
                .help("Add a person to this context")
                
                Button {
                    showingEditSheet = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .help("Edit context details")
                
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Delete this context")
            }
        }
        .task(id: context.id) {
            loadNotes()
        }
        .sheet(isPresented: $showingEditSheet) {
            EditContextSheet(context: context, isPresented: $showingEditSheet)
        }
        .sheet(isPresented: $showingAddParticipantSheet) {
            AddParticipantSheet(context: context, isPresented: $showingAddParticipantSheet)
        }
        .sheet(item: $editingNote) { note in
            NoteEditorView(note: note) {
                loadNotes()
            }
        }
        .confirmationDialog(
            "Delete \(context.name)?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteContext()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone. All participations and related data will be removed.")
        }
    }
    
    // MARK: - Header
    
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                // Icon
                Image(systemName: context.kind.icon)
                    .font(.system(size: 48))
                    .foregroundStyle(context.kind.color)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.name)
                        .font(.title)
                        .bold()
                    
                    HStack(spacing: 8) {
                        Label(context.kind.displayName, systemImage: context.kind.icon)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        if !context.participations.isEmpty {
                            Text("•")
                                .foregroundStyle(.secondary)
                            
                            Label("\(context.participations.count) participants", systemImage: "person.2")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Spacer()
            }
            
            // Alert badges
            if context.consentAlertCount > 0 || context.reviewAlertCount > 0 || context.followUpAlertCount > 0 {
                HStack(spacing: 12) {
                    if context.consentAlertCount > 0 {
                        Label("\(context.consentAlertCount) consent required", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    
                    if context.reviewAlertCount > 0 {
                        Label("\(context.reviewAlertCount) needs review", systemImage: "bell.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    
                    if context.followUpAlertCount > 0 {
                        Label("\(context.followUpAlertCount) follow-up", systemImage: "clock.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
                .padding(.top, 4)
            }
        }
    }
    
    // MARK: - Participants Section
    
    private var participantsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Participants", systemImage: "person.2")
                    .font(.headline)
                
                Spacer()
                
                Button {
                    showingAddParticipantSheet = true
                } label: {
                    Label("Add", systemImage: "plus.circle")
                        .font(.caption)
                }
            }
            
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(context.participations.enumerated()), id: \.offset) { _, participation in
                    if let person = participation.person {
                        ParticipantRow(participation: participation, person: person)
                    }
                }
            }
        }
    }
    
    // MARK: - Products Section
    
    private var productsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Products", systemImage: "doc.text")
                .font(.headline)
            
            Text("Product management coming in future phases")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    
    // MARK: - Insights Section
    
    private var insightsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Insights", systemImage: "lightbulb")
                .font(.headline)
            
            Text("AI-generated insights coming in Phase I")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    
    // MARK: - Notes Section (Phase L-2)

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Notes", systemImage: "note.text")
                .font(.headline)

            // Inline capture — always visible
            InlineNoteCaptureView(
                linkedPerson: nil,
                linkedContext: context,
                onSaved: { loadNotes() }
            )

            if contextNotes.isEmpty {
                Text("No notes yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(contextNotes.prefix(5), id: \.id) { note in
                        Button {
                            editingNote = note
                        } label: {
                            NoteRowView(note: note)
                        }
                        .buttonStyle(.plain)
                    }

                    if contextNotes.count > 5 {
                        Button(action: {
                            // TODO: Show all notes view
                        }) {
                            Text("Show all \(contextNotes.count) notes")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
    
    // MARK: - Metadata Section
    
    private var metadataSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Details", systemImage: "info.circle")
                    .font(.headline)
                
                Divider()
                
                LabeledContent("ID", value: context.id.uuidString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                LabeledContent("Type", value: context.kind.displayName)
                    .font(.caption)
            }
        }
    }
    
    // MARK: - Actions
    
    private func deleteContext() {
        Task {
            do {
                try ContextsRepository.shared.delete(context: context)
            } catch {
                // Error is non-recoverable in this context
            }
        }
    }
    
    private func loadNotes() {
        Task {
            do {
                contextNotes = try repository.fetchNotes(forContext: context)
            } catch {
                // Notes loading failure is non-critical
            }
        }
    }
}

// MARK: - Note Row View (Phase L-2)

private struct NoteRowView: View {
    let note: SamNote

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: note.isAnalyzed ? "brain.head.profile" : "note.text")
                    .foregroundStyle(note.isAnalyzed ? .purple : .secondary)
                    .font(.caption)

                Text(note.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if !note.extractedActionItems.isEmpty {
                    let pendingCount = note.extractedActionItems.filter { $0.status == .pending }.count
                    if pendingCount > 0 {
                        Text("\(pendingCount)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.2))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }
            }

            if let summary = note.summary {
                Text(summary)
                    .font(.body)
                    .lineLimit(2)
            } else {
                Text(note.content)
                    .font(.body)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }

            if !note.extractedTopics.isEmpty {
                HStack(spacing: 4) {
                    ForEach(note.extractedTopics.prefix(3), id: \.self) { topic in
                        Text(topic)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.1))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                    if note.extractedTopics.count > 3 {
                        Text("+\(note.extractedTopics.count - 3)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Participant Row

private struct ParticipantRow: View {
    let participation: ContextParticipation
    let person: SamPerson
    
    var body: some View {
        HStack(spacing: 12) {
            // Photo or icon
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
            
            // Name and badges
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(person.displayNameCache ?? person.displayName)
                        .font(.body)
                    
                    if participation.isPrimary {
                        Text("PRIMARY")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.2))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                }
                
                if !participation.roleBadges.isEmpty {
                    Text(participation.roleBadges.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                if let note = participation.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Edit Context Sheet

private struct EditContextSheet: View {
    let context: SamContext
    @Binding var isPresented: Bool
    
    @State private var name: String
    @State private var selectedKind: ContextKind
    @State private var isSaving = false
    @State private var errorMessage: String?
    
    init(context: SamContext, isPresented: Binding<Bool>) {
        self.context = context
        self._isPresented = isPresented
        self._name = State(initialValue: context.name)
        self._selectedKind = State(initialValue: context.kind)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                
                Picker("Type", selection: $selectedKind) {
                    ForEach([ContextKind.household, .business], id: \.self) { kind in
                        Label(kind.displayName, systemImage: kind.icon)
                            .tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding()
            .navigationTitle("Edit Context")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveChanges()
                    }
                    .disabled(name.isEmpty || isSaving)
                }
            }
        }
        .frame(width: 400, height: 250)
    }
    
    private func saveChanges() {
        isSaving = true
        errorMessage = nil
        
        Task {
            do {
                try ContextsRepository.shared.update(
                    context: context,
                    name: name,
                    kind: selectedKind
                )
                
                await MainActor.run {
                    isPresented = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSaving = false
                }
            }
        }
    }
}

// MARK: - Add Participant Sheet

private struct AddParticipantSheet: View {
    let context: SamContext
    @Binding var isPresented: Bool
    
    @Query private var allPeople: [SamPerson]
    @State private var selectedPerson: SamPerson?
    @State private var roleBadges: String = ""
    @State private var isPrimary = false
    @State private var note: String = ""
    @State private var isAdding = false
    @State private var errorMessage: String?
    
    var availablePeople: [SamPerson] {
        // Filter out people already in this context
        let existingPeopleIDs = Set(context.participations.compactMap { $0.person?.id })
        return allPeople.filter { !existingPeopleIDs.contains($0.id) }
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Picker("Person", selection: $selectedPerson) {
                    Text("Select a person").tag(nil as SamPerson?)
                    
                    ForEach(availablePeople, id: \.id) { person in
                        Text(person.displayNameCache ?? person.displayName)
                            .tag(person as SamPerson?)
                    }
                }
                
                TextField("Roles (comma-separated)", text: $roleBadges)
                    .textFieldStyle(.roundedBorder)
                    .help("e.g., Client, Primary Insured")
                
                Toggle("Primary participant", isOn: $isPrimary)
                
                TextField("Note (optional)", text: $note, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...5)
                
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding()
            .navigationTitle("Add Participant")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addParticipant()
                    }
                    .disabled(selectedPerson == nil || isAdding)
                }
            }
        }
        .frame(width: 450, height: 350)
    }
    
    private func addParticipant() {
        guard let person = selectedPerson else { return }
        
        isAdding = true
        errorMessage = nil
        
        Task {
            do {
                let badges = roleBadges
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                
                try ContextsRepository.shared.addParticipant(
                    person: person,
                    to: context,
                    roleBadges: badges,
                    isPrimary: isPrimary,
                    note: note.isEmpty ? nil : note
                )
                
                await MainActor.run {
                    isPresented = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isAdding = false
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Household with Participants") {
    let container = SAMModelContainer.shared
    ContextsRepository.shared.configure(container: container)
    PeopleRepository.shared.configure(container: container)
    
    let context = ModelContext(container)
    
    // Create people
    let john = SamPerson(
        id: UUID(),
        displayName: "John Smith",
        roleBadges: ["Client"],
        contactIdentifier: "1",
        email: "john@example.com"
    )
    john.displayNameCache = "John Smith"
    
    let jane = SamPerson(
        id: UUID(),
        displayName: "Jane Smith",
        roleBadges: [],
        contactIdentifier: "2",
        email: "jane@example.com"
    )
    jane.displayNameCache = "Jane Smith"
    
    // Create context
    let household = SamContext(
        id: UUID(),
        name: "Smith Family",
        kind: .household,
        reviewAlertCount: 1
    )
    
    // Create participations
    let participation1 = ContextParticipation(
        id: UUID(),
        person: john,
        context: household,
        roleBadges: ["Primary Insured", "Decision Maker"],
        isPrimary: true
    )
    
    let participation2 = ContextParticipation(
        id: UUID(),
        person: jane,
        context: household,
        roleBadges: ["Spouse", "Beneficiary"]
    )
    
    household.participations = [participation1, participation2]
    
    context.insert(john)
    context.insert(jane)
    context.insert(household)
    try? context.save()
    
    return NavigationStack {
        ContextDetailView(context: household)
            .modelContainer(container)
    }
    .frame(width: 700, height: 600)
}

#Preview("Business Context") {
    let container = SAMModelContainer.shared
    ContextsRepository.shared.configure(container: container)
    
    let context = ModelContext(container)
    
    let business = SamContext(
        id: UUID(),
        name: "Acme Corp",
        kind: .business,
        followUpAlertCount: 2
    )
    
    context.insert(business)
    try? context.save()
    
    return NavigationStack {
        ContextDetailView(context: business)
            .modelContainer(container)
    }
    .frame(width: 700, height: 600)
}
