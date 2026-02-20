//
//  PersonDetailView.swift
//  SAM_crm
//
//  Created on February 10, 2026.
//  Phase D: First Feature - People
//
//  Detail view for a single person showing contact info, relationships,
//  evidence, insights, and notes.
//

import SwiftUI
import SwiftData
import Contacts
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "PersonDetailView")

struct PersonDetailView: View {
    
    // MARK: - Properties
    
    let person: SamPerson
    
    // MARK: - Dependencies
    
    @State private var contactsService = ContactsService.shared
    @State private var notesRepository = NotesRepository.shared
    
    // MARK: - State
    
    @State private var fullContact: ContactDTO?
    @State private var isLoadingContact = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var showingNoteEditor = false
    @State private var showingContextPicker = false
    @State private var personNotes: [SamNote] = []
    
    // MARK: - Body
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header with photo and basic info
                headerSection
                    .padding(.horizontal)
                    .padding(.top)
                
                // Debug: Show loading state
                if isLoadingContact {
                    HStack {
                        ProgressView()
                        Text("Loading contact details...")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }
                
                // Contact information
                if let contact = fullContact {
                    contactSections(contact)
                } else if !isLoadingContact && person.contactIdentifier != nil {
                    // Show helpful message if loading failed
                    errorStateSection
                        .padding()
                }
                
                // SAM-specific sections
                samDataSections
            }
        }
        .navigationTitle("")  // Remove title since we show it in the header
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showingNoteEditor = true
                } label: {
                    Label("Add Note", systemImage: "note.text.badge.plus")
                }
                .help("Add a note about this person")
                
                if person.contactIdentifier != nil {
                    Button {
                        openInContacts()
                    } label: {
                        Label("Open in Contacts", systemImage: "person.crop.circle")
                    }
                    .help("Open this person in Apple Contacts")
                } else {
                    Button {
                        createInContacts()
                    } label: {
                        Label("Create in Contacts", systemImage: "person.crop.circle.badge.plus")
                    }
                    .help("Create this person in Apple Contacts")
                }
                
                Menu {
                    Button("Add to Context", systemImage: "building.2") {
                        showingContextPicker = true
                    }
                    
                    Divider()
                    
                    Button("Refresh Contact", systemImage: "arrow.clockwise") {
                        Task {
                            await loadFullContact()
                        }
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .task(id: person.id) {
            await loadFullContact()
            loadNotes()
        }
        .sheet(isPresented: $showingNoteEditor) {
            NoteEditorView(linkedPerson: person) {
                loadNotes()
            }
        }
        .sheet(isPresented: $showingContextPicker) {
            ContextPickerSheet(person: person)
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        HStack(alignment: .top, spacing: 16) {
            // Left side: Name, company, phone, email
            VStack(alignment: .leading, spacing: 6) {
                // Name
                Text(person.displayNameCache ?? person.displayName)
                    .font(.system(size: 28, weight: .bold))
                
                // Company and job title
                if let contact = fullContact {
                    if !contact.organizationName.isEmpty {
                        HStack(alignment: .bottom, spacing: 4) {
                            Text(contact.organizationName)
                                .font(.body)
                            if !contact.jobTitle.isEmpty {
                                Text("•")
                                    .font(.caption)
                                    .foregroundStyle(.green.opacity(0.7))
                                Text(contact.jobTitle)
                                    .font(.caption)
                                    .foregroundStyle(.green.opacity(0.7))
                            }
                        }
                    } else if !contact.jobTitle.isEmpty {
                        Text(contact.jobTitle)
                            .font(.body)
                    }
                    
                    // Primary phone
                    if let primaryPhone = contact.phoneNumbers.first {
                        HStack(alignment: .bottom, spacing: 4) {
                            Text(primaryPhone.number)
                                .font(.body)
                            if let label = primaryPhone.label, !label.isEmpty {
                                Text(label)
                                    .font(.caption)
                                    .foregroundStyle(.green.opacity(0.7))
                            }
                        }
                    }
                    
                    // Primary email
                    if let primaryEmail = contact.emailAddresses.first {
                        Text(primaryEmail)
                            .font(.body)
                            .foregroundStyle(.blue)
                    }
                }
                
                // Role badges
                if !person.roleBadges.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(person.roleBadges, id: \.self) { badge in
                            Text(badge)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.blue.opacity(0.15))
                                .foregroundStyle(.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    .padding(.top, 2)
                }
            }
            
            Spacer()
            
            // Right side: Photo at 75% opacity
            if let photoData = person.photoThumbnailCache,
               let nsImage = NSImage(data: photoData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 75, height: 75)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .opacity(0.75)
            } else {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .frame(width: 75, height: 75)
                    .foregroundStyle(.secondary)
                    .opacity(0.75)
            }
        }
        .padding(.bottom, 16)
    }
    
    // MARK: - Contact Info Section
    
    @ViewBuilder
    private func contactSections(_ contact: ContactDTO) -> some View {
        VStack(spacing: 0) {
            // Phone Numbers Section
            if contact.phoneNumbers.count > 1 {
                contactSection(title: "Phone") {
                    ForEach(Array(contact.phoneNumbers.dropFirst().enumerated()), id: \.offset) { _, phone in
                        contactRow(
                            value: phone.number,
                            label: phone.label,
                            action: { copyToClipboard(phone.number) }
                        )
                    }
                }
            }
            
            // Email Addresses Section
            if contact.emailAddresses.count > 1 {
                contactSection(title: "Email") {
                    ForEach(Array(contact.emailAddresses.dropFirst().enumerated()), id: \.offset) { _, email in
                        contactRow(
                            value: email,
                            label: nil,
                            action: { copyToClipboard(email) }
                        )
                    }
                }
            }
            
            // Addresses Section
            if !contact.postalAddresses.isEmpty {
                contactSection(title: "Address") {
                    ForEach(contact.postalAddresses) { address in
                        contactRow(
                            value: address.formattedAddress,
                            label: address.label,
                            action: { copyToClipboard(address.formattedAddress) },
                            isMultiline: true
                        )
                    }
                }
            }
            
            // Online Presence Section
            if !contact.urlAddresses.isEmpty || !contact.socialProfiles.isEmpty {
                contactSection(title: "Online Presence") {
                    // Websites
                    ForEach(Array(contact.urlAddresses.enumerated()), id: \.offset) { _, url in
                        contactRow(
                            value: url,
                            label: "website",
                            action: {
                                if let nsURL = URL(string: url) {
                                    NSWorkspace.shared.open(nsURL)
                                }
                            }
                        )
                    }
                    
                    // Social profiles
                    ForEach(contact.socialProfiles) { profile in
                        contactRow(
                            value: profile.username,
                            label: profile.service.lowercased(),
                            action: {
                                if let urlString = profile.urlString, let url = URL(string: urlString) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        )
                    }
                }
            }
            
            // Messaging Section
            if !contact.instantMessageAddresses.isEmpty {
                contactSection(title: "Messaging") {
                    ForEach(contact.instantMessageAddresses) { im in
                        contactRow(
                            value: im.username,
                            label: im.service.lowercased(),
                            action: { copyToClipboard(im.username) }
                        )
                    }
                }
            }
            
            // Related People Section
            if !contact.contactRelations.isEmpty {
                contactSection(title: "Related People") {
                    ForEach(contact.contactRelations) { relation in
                        contactRow(
                            value: relation.name,
                            label: relation.label?.lowercased(),
                            action: nil
                        )
                    }
                }
            }
            
            // Birthday Section
            if let birthday = contact.birthday, let birthdayString = formattedBirthday(from: birthday) {
                contactSection(title: "Birthday") {
                    contactRow(
                        value: birthdayString,
                        label: nil,
                        action: nil
                    )
                }
            }
        }
    }
    
    // Helper view for a contact section
    private func contactSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 6)
            
            Divider()
                .padding(.horizontal)
            
            // Section content
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
        }
    }
    
    // Helper view for a contact row
    private func contactRow(value: String, label: String?, action: (() -> Void)?, isMultiline: Bool = false) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            // Value and label
            if isMultiline {
                // For multiline content (like addresses), show on one line
                HStack(alignment: .bottom, spacing: 4) {
                    Text(value)
                        .font(.body)
                    if let label = label, !label.isEmpty {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.green.opacity(0.7))
                    }
                }
            } else {
                HStack(alignment: .bottom, spacing: 4) {
                    Text(value)
                        .font(.body)
                    if let label = label, !label.isEmpty {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.green.opacity(0.7))
                    }
                }
            }
            
            Spacer()
            
            // Action button
            if let action = action {
                Button(action: action) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
    
    // Error state section
    private var errorStateSection: some View {
        GroupBox {
            VStack(spacing: 12) {
                Label("Contact Details Unavailable", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(.orange)
                
                Text("Full contact details could not be loaded. This may be because:")
                    .font(.body)
                
                VStack(alignment: .leading, spacing: 8) {
                    Label("Contacts access was not granted", systemImage: "hand.raised.fill")
                    Label("The contact was deleted from Apple Contacts", systemImage: "trash")
                    Label("The app needs to be restarted", systemImage: "arrow.clockwise")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                
                Divider()
                
                HStack(spacing: 12) {
                    Button("Refresh") {
                        Task {
                            await loadFullContact()
                        }
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }
    
    // SAM-specific data sections
    @ViewBuilder
    private var samDataSections: some View {
        VStack(spacing: 0) {
            // Relationship Health (Phase K)
            samSection(title: "Relationship Health") {
                RelationshipHealthView(
                    health: MeetingPrepCoordinator.shared.computeHealth(for: person)
                )
            }

            // Alert counts
            if person.consentAlertsCount > 0 || person.reviewAlertsCount > 0 {
                samSection(title: "Alerts") {
                    alertsContent
                }
            }
            
            // Participations (contexts)
            if !person.participations.isEmpty {
                samSection(title: "Contexts") {
                    participationsContent
                }
            }
            
            // Coverages (insurance/financial products)
            if !person.coverages.isEmpty {
                samSection(title: "Coverages") {
                    coveragesContent
                }
            }
            
            // Notes (Phase H)
            notesSection
            
            // Insights
            if !person.insights.isEmpty {
                samSection(title: "Insights") {
                    insightsContent
                }
            }
            
            // Sync info
            samSection(title: "Sync") {
                syncInfoContent
            }
        }
    }
    
    // Helper view for SAM data sections
    private func samSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 6)
            
            Divider()
                .padding(.horizontal)
            
            // Section content
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }
    
    private var alertsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if person.consentAlertsCount > 0 {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    
                    Text("Consent review needed")
                        .font(.body)
                    
                    Spacer()
                    
                    Text("\(person.consentAlertsCount)")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.2))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                .padding(.vertical, 4)
            }
            
            if person.reviewAlertsCount > 0 {
                HStack {
                    Image(systemName: "bell.fill")
                        .foregroundStyle(.red)
                    
                    Text("Needs follow-up")
                        .font(.body)
                    
                    Spacer()
                    
                    Text("\(person.reviewAlertsCount)")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.red.opacity(0.2))
                        .foregroundStyle(.red)
                        .clipShape(Capsule())
                }
                .padding(.vertical, 4)
            }
        }
    }
    
    private var participationsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(person.participations.enumerated()), id: \.offset) { index, participation in
                if let context = participation.context {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.name)
                                .font(.body)
                            
                            if !participation.roleBadges.isEmpty {
                                Text(participation.roleBadges.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.green.opacity(0.7))
                            }
                        }
                        
                        Spacer()
                        
                        Text(context.kind.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.purple.opacity(0.2))
                            .foregroundStyle(.purple)
                            .clipShape(Capsule())
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
    
    private var coveragesContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(person.coverages.enumerated()), id: \.offset) { index, coverage in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        if let product = coverage.product {
                            Text(product.name)
                                .font(.body)
                            
                            if let context = product.context {
                                Text(context.name)
                                    .font(.caption)
                                    .foregroundStyle(.green.opacity(0.7))
                            }
                        } else {
                            Text("Unknown Product")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    Text(coverage.role.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.2))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                }
                .padding(.vertical, 4)
            }
        }
    }
    
    private var insightsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(person.insights.enumerated()), id: \.offset) { index, insight in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(insight.kind.rawValue)
                            .font(.body)
                            .bold()
                        
                        Spacer()
                        
                        Text(insight.createdAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.green.opacity(0.7))
                    }
                    
                    Text(insight.message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                    
                    HStack {
                        Text(insight.kind.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.indigo.opacity(0.2))
                            .foregroundStyle(.indigo)
                            .clipShape(Capsule())
                        
                        Spacer()
                        
                        Text("Confidence: \(Int(insight.confidence * 100))%")
                            .font(.caption)
                            .foregroundStyle(.green.opacity(0.7))
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
    
    // Notes section (Phase H)
    private var notesSection: some View {
        samSection(title: "Notes") {
            if personNotes.isEmpty {
                VStack(spacing: 8) {
                    Text("No notes yet")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    
                    Button(action: {
                        showingNoteEditor = true
                    }) {
                        Label("Add First Note", systemImage: "plus.circle")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(personNotes.prefix(5), id: \.id) { note in
                        NoteRowView(note: note)
                            .padding(.vertical, 4)
                    }
                    
                    if personNotes.count > 5 {
                        Button(action: {
                            // TODO: Show all notes view
                        }) {
                            Text("Show all \(personNotes.count) notes")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }
    
    private var syncInfoContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let syncedAt = person.lastSyncedAt {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                    
                    Text("Last synced: \(syncedAt, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            if let identifier = person.contactIdentifier {
                HStack {
                    Image(systemName: "number")
                        .foregroundStyle(.secondary)
                    
                    Text("Contact ID: \(identifier)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            if person.isArchived {
                HStack {
                    Image(systemName: "archivebox")
                        .foregroundStyle(.orange)
                    
                    Text("This contact has been deleted from Apple Contacts")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
    
    // MARK: - Data Loading
    
    private func loadNotes() {
        Task {
            do {
                personNotes = try notesRepository.fetchNotes(forPerson: person)
            } catch {
                logger.error("Failed to load notes: \(error)")
            }
        }
    }
    
    // MARK: - Actions
    
    private func loadFullContact() async {
        guard let identifier = person.contactIdentifier else {
            errorMessage = "This person has no linked contact identifier"
            return
        }
        
        // Check authorization first
        let authStatus = await contactsService.authorizationStatus()
        if authStatus != .authorized {
            logger.warning("Not authorized to access Contacts (status: \(authStatus.rawValue))")
            errorMessage = "Contacts access not granted. Please grant permission in Settings → Privacy & Security → Contacts"
            showingError = true
            return
        }
        
        isLoadingContact = true
        
        // Fetch full contact with all keys
        let contact = await contactsService.fetchContact(
            identifier: identifier,
            keys: .full
        )
        
        if let contact = contact {
            fullContact = contact
        } else {
            logger.error("Failed to load contact for identifier: \(identifier, privacy: .public)")
            errorMessage = "Could not load contact details. The contact may have been deleted from Apple Contacts."
            showingError = true
        }
        
        isLoadingContact = false
    }
    
    private func openInContacts() {
        guard let identifier = person.contactIdentifier else { return }

        // Open Contacts app to this person
        let url = URL(string: "addressbook://\(identifier)")!
        NSWorkspace.shared.open(url)
    }

    private func createInContacts() {
        Task {
            let displayName = person.displayNameCache ?? person.displayName
            let email = person.emailCache ?? person.email

            guard let contactDTO = await contactsService.createContact(
                fullName: displayName,
                email: email,
                note: nil
            ) else {
                errorMessage = "Failed to create contact in Apple Contacts"
                showingError = true
                return
            }

            // Link the person to the new contact
            do {
                try PeopleRepository.shared.upsert(contact: contactDTO)
                // Reload contact details
                await loadFullContact()
                logger.info("Created contact for \(displayName, privacy: .public)")
            } catch {
                errorMessage = "Contact created but failed to link: \(error.localizedDescription)"
                showingError = true
            }
        }
    }
    
    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    
    private func formattedBirthday(from components: DateComponents) -> String? {
        guard let month = components.month, let day = components.day else { return nil }
        var comps = DateComponents()
        comps.calendar = Calendar.current
        comps.timeZone = TimeZone.current
        comps.year = components.year ?? 2000
        comps.month = month
        comps.day = day
        guard let date = comps.calendar?.date(from: comps) ?? Calendar.current.date(from: comps) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        if components.year == nil {
            formatter.setLocalizedDateFormatFromTemplate("MMMM d")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMMM d, yyyy")
        }
        return formatter.string(from: date)
    }
}

// MARK: - Note Row View (Phase H)

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
    }
}

// MARK: - Context Picker Sheet

private struct ContextPickerSheet: View {
    let person: SamPerson
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SamContext.name) private var contexts: [SamContext]
    @State private var searchText = ""

    private var filteredContexts: [SamContext] {
        if searchText.isEmpty { return contexts }
        return contexts.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                if filteredContexts.isEmpty {
                    Text("No contexts found")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredContexts, id: \.id) { context in
                        Button {
                            addPerson(to: context)
                        } label: {
                            HStack {
                                Text(context.name)
                                    .foregroundStyle(.primary)

                                Spacer()

                                Text(context.kind.rawValue)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.purple.opacity(0.2))
                                    .foregroundStyle(.purple)
                                    .clipShape(Capsule())
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search contexts")
            .navigationTitle("Add to Context")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 350, minHeight: 300)
    }

    private func addPerson(to context: SamContext) {
        do {
            try ContextsRepository.shared.addParticipant(person: person, to: context)
            dismiss()
        } catch {
            logger.error("Failed to add person to context: \(error)")
        }
    }
}

// MARK: - Flow Layout (for wrapping badges)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0

        let maxWidth = proposal.width ?? .infinity

        for size in sizes {
            if lineWidth + size.width > maxWidth {
                totalHeight += lineHeight + spacing
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth += size.width + spacing
                lineHeight = max(lineHeight, size.height)
            }
            
            totalWidth = max(totalWidth, lineWidth)
        }
        
        totalHeight += lineHeight
        
        return CGSize(width: totalWidth, height: totalHeight)
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var y: CGFloat = bounds.minY
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            
            if lineWidth + size.width > maxWidth {
                y += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            
            subview.place(
                at: CGPoint(x: bounds.minX + lineWidth, y: y),
                proposal: ProposedViewSize(size)
            )
            
            lineWidth += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Preview

#Preview {
    let container = SAMModelContainer.shared
    let context = ModelContext(container)
    
    let person = SamPerson(
        id: UUID(),
        displayName: "John Doe",
        roleBadges: ["Client", "High Priority"],
        contactIdentifier: "123",
        email: "john@example.com",
        consentAlertsCount: 1,
        reviewAlertsCount: 3
    )
    person.displayNameCache = "John Doe"
    person.emailCache = "john@example.com"
    person.lastSyncedAt = Date()
    
    context.insert(person)
    
    // Add sample insight
    let insight = SamInsight(
        samPerson: person,
        kind: .followUpNeeded,
        message: "Haven't connected with John in over 2 weeks. Consider scheduling a check-in.",
        confidence: 0.85
    )
    context.insert(insight)
    
    // Note: SamNote will be implemented in Phase J
    // For now, previews show only existing relationships
    
    try? context.save()
    
    return NavigationStack {
        PersonDetailView(person: person)
            .modelContainer(container)
    }
    .frame(width: 700, height: 800)
}

// MARK: - Relationship Health View (shared, used in PersonDetailView + MeetingPrepSection)

struct RelationshipHealthView: View {

    let health: RelationshipHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Last interaction + health dot
            HStack(spacing: 6) {
                Circle()
                    .fill(health.statusColor)
                    .frame(width: 8, height: 8)
                Text("Last interaction: \(health.statusLabel)")
                    .font(.subheadline)

                Spacer()

                // Trend indicator
                trendIndicator
            }

            // Frequency chips
            HStack(spacing: 8) {
                frequencyChip(label: "30d", count: health.interactionCount30)
                frequencyChip(label: "60d", count: health.interactionCount90 - health.interactionCount30)
                frequencyChip(label: "90d", count: health.interactionCount90)
            }
        }
        .padding(.vertical, 6)
    }

    private var trendIndicator: some View {
        Group {
            switch health.trend {
            case .increasing:
                Label("Increasing", systemImage: "arrow.up.right")
                    .foregroundStyle(.green)
            case .stable:
                Label("Stable", systemImage: "arrow.right")
                    .foregroundStyle(.secondary)
            case .decreasing:
                Label("Decreasing", systemImage: "arrow.down.right")
                    .foregroundStyle(.orange)
            case .noData:
                Label("No data", systemImage: "minus")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private func frequencyChip(label: String, count: Int) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
