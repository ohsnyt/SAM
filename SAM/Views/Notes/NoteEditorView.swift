//
//  NoteEditorView.swift
//  SAM_crm
//
//  Created by Assistant on 2/11/26.
//  Phase H: Notes & Note Intelligence
//
//  Sheet for creating and editing notes with entity linking and AI analysis.
//

import SwiftUI
import SwiftData

struct NoteEditorView: View {
    
    // MARK: - Environment
    
    @Environment(\.dismiss) private var dismiss
    
    // MARK: - Parameters
    
    /// Existing note to edit (nil for new note)
    let note: SamNote?
    
    /// Pre-linked person (for notes created from person detail)
    let linkedPerson: SamPerson?
    
    /// Pre-linked context (for notes created from context detail)
    let linkedContext: SamContext?
    
    /// Pre-linked evidence (for notes attached to inbox items)
    let linkedEvidence: SamEvidenceItem?
    
    /// Callback after save
    let onSave: () -> Void
    
    // MARK: - Dependencies
    
    @State private var repository = NotesRepository.shared
    @State private var coordinator = NoteAnalysisCoordinator.shared
    
    // MARK: - State
    
    @State private var content: String = ""
    @State private var selectedPeople: [SamPerson] = []
    @State private var selectedContexts: [SamContext] = []
    @State private var selectedEvidence: [SamEvidenceItem] = []
    
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingLinkPicker = false
    
    // MARK: - Queries
    
    @Query private var allPeople: [SamPerson]
    @Query private var allContexts: [SamContext]
    
    // MARK: - Initialization
    
    init(
        note: SamNote? = nil,
        linkedPerson: SamPerson? = nil,
        linkedContext: SamContext? = nil,
        linkedEvidence: SamEvidenceItem? = nil,
        onSave: @escaping () -> Void
    ) {
        self.note = note
        self.linkedPerson = linkedPerson
        self.linkedContext = linkedContext
        self.linkedEvidence = linkedEvidence
        self.onSave = onSave
        
        // Initialize state from existing note
        if let note = note {
            _content = State(initialValue: note.content)
            _selectedPeople = State(initialValue: note.linkedPeople)
            _selectedContexts = State(initialValue: note.linkedContexts)
            _selectedEvidence = State(initialValue: note.linkedEvidence)
        } else {
            // Initialize with pre-linked entities
            var people: [SamPerson] = []
            var contexts: [SamContext] = []
            var evidence: [SamEvidenceItem] = []
            
            if let person = linkedPerson { people.append(person) }
            if let context = linkedContext { contexts.append(context) }
            if let item = linkedEvidence { evidence.append(item) }
            
            _selectedPeople = State(initialValue: people)
            _selectedContexts = State(initialValue: contexts)
            _selectedEvidence = State(initialValue: evidence)
        }
    }
    
    // MARK: - Body
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $content)
                        .frame(minHeight: 200)
                        .font(.body)
                } header: {
                    Text("Note Content")
                }
                
                Section {
                    if !selectedPeople.isEmpty {
                        ForEach(selectedPeople, id: \.id) { person in
                            HStack {
                                Image(systemName: "person.fill")
                                    .foregroundStyle(.blue)
                                Text(person.displayNameCache ?? person.displayName)
                                Spacer()
                                Button(action: {
                                    selectedPeople.removeAll(where: { $0.id == person.id })
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    
                    if !selectedContexts.isEmpty {
                        ForEach(selectedContexts, id: \.id) { context in
                            HStack {
                                Image(systemName: context.kind.icon)
                                    .foregroundStyle(context.kind.color)
                                Text(context.name)
                                Spacer()
                                Button(action: {
                                    selectedContexts.removeAll(where: { $0.id == context.id })
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    
                    Button(action: {
                        showingLinkPicker = true
                    }) {
                        Label("Link Person or Context", systemImage: "link.badge.plus")
                    }
                } header: {
                    Text("Linked Entities")
                } footer: {
                    Text("Link this note to people or contexts for better organization")
                }
                
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
                
                // AI Analysis Info
                if note?.isAnalyzed == true {
                    Section {
                        Label("This note has been analyzed by AI", systemImage: "brain.head.profile")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle(note == nil ? "New Note" : "Edit Note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button(note == nil ? "Create" : "Save") {
                        saveNote()
                    }
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .sheet(isPresented: $showingLinkPicker) {
                LinkPickerSheet(
                    selectedPeople: $selectedPeople,
                    selectedContexts: $selectedContexts,
                    allPeople: allPeople,
                    allContexts: allContexts
                )
            }
        }
    }
    
    // MARK: - Actions
    
    private func saveNote() {
        isSaving = true
        errorMessage = nil
        
        Task { @MainActor in
            do {
                let noteToAnalyze: SamNote
                
                if let existingNote = note {
                    // Update existing note
                    try repository.update(note: existingNote, content: content)
                    try repository.updateLinks(
                        note: existingNote,
                        peopleIDs: selectedPeople.map { $0.id },
                        contextIDs: selectedContexts.map { $0.id },
                        evidenceIDs: selectedEvidence.map { $0.id }
                    )
                    noteToAnalyze = existingNote
                } else {
                    // Create new note - pass IDs instead of objects
                    let newNote = try repository.create(
                        content: content,
                        linkedPeopleIDs: selectedPeople.map { $0.id },
                        linkedContextIDs: selectedContexts.map { $0.id },
                        linkedEvidenceIDs: selectedEvidence.map { $0.id }
                    )
                    noteToAnalyze = newNote
                }
                
                // Success - notify and dismiss immediately
                onSave()
                dismiss()
                
                // Trigger analysis in background (don't await)
                // This allows the sheet to close immediately while analysis happens
                Task {
                    await coordinator.analyzeNote(noteToAnalyze)
                }
                
            } catch {
                // Error - show message and re-enable button
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

// MARK: - Link Picker Sheet

private struct LinkPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    @Binding var selectedPeople: [SamPerson]
    @Binding var selectedContexts: [SamContext]
    
    let allPeople: [SamPerson]
    let allContexts: [SamContext]
    
    @State private var searchText = ""
    @State private var selectedTab = 0
    
    var body: some View {
        NavigationStack {
            VStack {
                Picker("Type", selection: $selectedTab) {
                    Text("People").tag(0)
                    Text("Contexts").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()
                
                if selectedTab == 0 {
                    peopleList
                } else {
                    contextsList
                }
            }
            .navigationTitle("Link Entities")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search...")
        }
    }
    
    private var peopleList: some View {
        List {
            ForEach(filteredPeople, id: \.id) { person in
                Button(action: {
                    togglePerson(person)
                }) {
                    HStack {
                        Image(systemName: "person.fill")
                            .foregroundStyle(.blue)
                        Text(person.displayNameCache ?? person.displayName)
                        Spacer()
                        if selectedPeople.contains(where: { $0.id == person.id }) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    private var contextsList: some View {
        List {
            ForEach(filteredContexts, id: \.id) { context in
                Button(action: {
                    toggleContext(context)
                }) {
                    HStack {
                        Image(systemName: context.kind.icon)
                            .foregroundStyle(context.kind.color)
                        Text(context.name)
                        Spacer()
                        if selectedContexts.contains(where: { $0.id == context.id }) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    private var filteredPeople: [SamPerson] {
        guard !searchText.isEmpty else { return allPeople }
        let query = searchText.lowercased()
        return allPeople.filter {
            ($0.displayNameCache ?? $0.displayName).lowercased().contains(query)
        }
    }
    
    private var filteredContexts: [SamContext] {
        guard !searchText.isEmpty else { return allContexts }
        let query = searchText.lowercased()
        return allContexts.filter {
            $0.name.lowercased().contains(query)
        }
    }
    
    private func togglePerson(_ person: SamPerson) {
        if let index = selectedPeople.firstIndex(where: { $0.id == person.id }) {
            selectedPeople.remove(at: index)
        } else {
            selectedPeople.append(person)
        }
    }
    
    private func toggleContext(_ context: SamContext) {
        if let index = selectedContexts.firstIndex(where: { $0.id == context.id }) {
            selectedContexts.remove(at: index)
        } else {
            selectedContexts.append(context)
        }
    }
}

// MARK: - Preview

#Preview("New Note") {
    NoteEditorView(onSave: {})
        .modelContainer(SAMModelContainer.shared)
        .frame(width: 600, height: 500)
}

#Preview("Edit Note") {
    let container = SAMModelContainer.shared
    let context = ModelContext(container)
    
    let person = SamPerson(
        id: UUID(),
        displayName: "John Smith",
        roleBadges: ["Client"]
    )
    
    let note = SamNote(
        content: "Met with John and Sarah. New baby Emma born Jan 15.",
        summary: "Discussed life insurance needs for growing family",
        isAnalyzed: true
    )
    note.linkedPeople = [person]
    
    context.insert(person)
    context.insert(note)
    
    return NoteEditorView(note: note, onSave: {})
        .modelContainer(container)
        .frame(width: 600, height: 500)
}
