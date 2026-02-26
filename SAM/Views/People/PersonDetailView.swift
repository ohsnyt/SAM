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
    @State private var showingContextPicker = false
    @State private var personNotes: [SamNote] = []
    @State private var isEditingBadges = false
    @State private var customBadgeText = ""
    @State private var badgesBeforeEdit: Set<String> = []
    @State private var showingCorrectionSheet = false
    @State private var showingReferrerPicker = false
    @State private var recruitingStage: RecruitingStage?
    @State private var productionRecords: [ProductionRecord] = []
    @State private var showingProductionForm = false

    @Query(filter: #Predicate<SamPerson> { !$0.isArchived })
    private var allPeople: [SamPerson]
    
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
            recruitingStage = try? PipelineRepository.shared.fetchRecruitingStage(forPerson: person.id)
            productionRecords = (try? ProductionRepository.shared.fetchRecords(forPerson: person.id)) ?? []
        }
        .onReceive(NotificationCenter.default.publisher(for: .samUndoDidRestore)) { _ in
            loadNotes()
        }
        .sheet(isPresented: $showingContextPicker) {
            ContextPickerSheet(person: person)
        }
        .sheet(isPresented: $showingReferrerPicker) {
            ReferrerPickerSheet(
                person: person,
                candidates: allPeople.filter { $0.id != person.id && !$0.isMe }
            )
        }
        .sheet(isPresented: $showingCorrectionSheet, onDismiss: {
            loadNotes()
        }) {
            CorrectionSheetView(
                person: person,
                currentSummary: person.relationshipSummary ?? ""
            )
        }
        .sheet(isPresented: $showingProductionForm) {
            ProductionEntryForm(
                personName: person.displayNameCache ?? person.displayName,
                personID: person.id,
                onSave: {
                    productionRecords = (try? ProductionRepository.shared.fetchRecords(forPerson: person.id)) ?? []
                }
            )
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
                roleBadgesView

                // Channel preference
                if !person.isMe {
                    channelPreferenceView
                    cadencePreferenceView
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
    
    // MARK: - Role Badges

    private static let predefinedBadges = [
        "Client", "Applicant", "Lead", "Vendor",
        "Agent", "External Agent", "Referral Partner"
    ]

    private var roleBadgesView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // Me badge (non-editable, set via Apple Contacts)
                if person.isMe {
                    Text("Me")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.secondary.opacity(0.2))
                        .foregroundStyle(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                // Display current badges
                ForEach(person.roleBadges, id: \.self) { badge in
                    let style = RoleBadgeStyle.forBadge(badge)
                    if isEditingBadges {
                        // Removable badge
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                person.roleBadges.removeAll { $0 == badge }
                            }
                            notifyBadgeChange()
                        } label: {
                            HStack(spacing: 4) {
                                Text(badge)
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(style.color.opacity(0.15))
                            .foregroundStyle(style.color)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(badge)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(style.color.opacity(0.15))
                            .foregroundStyle(style.color)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }

                // Edit toggle button
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if !isEditingBadges {
                            // Entering edit mode — snapshot current badges
                            badgesBeforeEdit = Set(person.roleBadges)
                        } else {
                            // Exiting edit mode — check for role transitions
                            customBadgeText = ""
                            let currentBadges = Set(person.roleBadges)
                            let added = currentBadges.subtracting(badgesBeforeEdit)
                            let removed = badgesBeforeEdit.subtracting(currentBadges)
                            if !added.isEmpty || !removed.isEmpty {
                                OutcomeEngine.shared.generateRoleTransitionOutcomes(
                                    for: person, addedRoles: added, removedRoles: removed
                                )
                                recordPipelineTransitions(added: added, removed: removed)
                            }
                        }
                        isEditingBadges.toggle()
                    }
                } label: {
                    Image(systemName: isEditingBadges ? "checkmark.circle.fill" : "pencil")
                        .font(.caption)
                        .foregroundStyle(isEditingBadges ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help(isEditingBadges ? "Done editing badges" : "Edit role badges")
            }

            // Edit mode: predefined options + custom entry
            if isEditingBadges {
                // Predefined badges (only show ones not already assigned)
                let available = Self.predefinedBadges.filter { !person.roleBadges.contains($0) }
                if !available.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(available, id: \.self) { badge in
                            let style = RoleBadgeStyle.forBadge(badge)
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    person.roleBadges.append(badge)
                                }
                                notifyBadgeChange()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 8, weight: .bold))
                                    Text(badge)
                                }
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(style.color.opacity(0.08))
                                .foregroundStyle(style.color.opacity(0.6))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Custom badge entry
                HStack(spacing: 6) {
                    TextField("Custom badge...", text: $customBadgeText)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(maxWidth: 200)
                        .onSubmit { addCustomBadge() }

                    Button("Add") { addCustomBadge() }
                        .font(.caption)
                        .disabled(customBadgeText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(.top, 2)
    }

    private func addCustomBadge() {
        let trimmed = customBadgeText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !person.roleBadges.contains(trimmed) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            person.roleBadges.append(trimmed)
        }
        customBadgeText = ""
        notifyBadgeChange()
    }

    private func notifyBadgeChange() {
        NotificationCenter.default.post(name: .samPersonDidChange, object: nil)
    }

    /// Record client pipeline transitions when role badges change.
    private func recordPipelineTransitions(added: Set<String>, removed: Set<String>) {
        let clientStages: Set<String> = ["Lead", "Applicant", "Client"]

        // For each added client-pipeline badge, record a transition
        for badge in added where clientStages.contains(badge) {
            // Find the removed client badge as the "from" stage, or "" if none
            let fromStage = removed.first(where: { clientStages.contains($0) }) ?? ""
            try? PipelineRepository.shared.recordTransition(
                personID: person.id,
                fromStage: fromStage,
                toStage: badge,
                pipelineType: .client
            )
        }

        // For each removed client badge with no replacement, record exit
        let addedClient = added.intersection(clientStages)
        for badge in removed where clientStages.contains(badge) && addedClient.isEmpty {
            try? PipelineRepository.shared.recordTransition(
                personID: person.id,
                fromStage: badge,
                toStage: "",
                pipelineType: .client
            )
        }
    }

    // MARK: - Channel Preference

    // MARK: - Recruiting Stage Section

    private var recruitingStageSection: some View {
        samSection(title: "Recruiting Pipeline") {
            VStack(alignment: .leading, spacing: 10) {
                // Stage progress dots
                HStack(spacing: 0) {
                    ForEach(RecruitingStageKind.allCases, id: \.rawValue) { kind in
                        let isCurrent = recruitingStage?.stage == kind
                        let isReached = (recruitingStage?.stage.order ?? -1) >= kind.order

                        VStack(spacing: 4) {
                            Circle()
                                .fill(isReached ? kind.color : Color.gray.opacity(0.3))
                                .frame(width: isCurrent ? 14 : 10, height: isCurrent ? 14 : 10)
                                .overlay {
                                    if isCurrent {
                                        Circle()
                                            .strokeBorder(.white, lineWidth: 2)
                                    }
                                }

                            Text(kind.rawValue)
                                .font(.system(size: 8))
                                .foregroundStyle(isReached ? .primary : .secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                // Current stage info + actions
                HStack(spacing: 12) {
                    if let stage = recruitingStage {
                        // Current stage badge
                        HStack(spacing: 4) {
                            Image(systemName: stage.stage.icon)
                                .font(.caption)
                            Text(stage.stage.rawValue)
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(stage.stage.color)

                        Spacer()

                        // Mentoring contact info
                        if let lastContact = stage.mentoringLastContact {
                            let days = Int(Date.now.timeIntervalSince(lastContact) / (24 * 60 * 60))
                            Text("\(days)d since contact")
                                .font(.caption)
                                .foregroundStyle(days > 14 ? .orange : .secondary)
                        }

                        // Log contact button
                        Button {
                            try? PipelineRepository.shared.updateMentoringContact(personID: person.id)
                            recruitingStage = try? PipelineRepository.shared.fetchRecruitingStage(forPerson: person.id)
                        } label: {
                            Label("Log Contact", systemImage: "hand.wave")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        // Advance button
                        if let nextStage = stage.stage.next {
                            Button {
                                try? PipelineRepository.shared.advanceRecruitingStage(
                                    personID: person.id,
                                    to: nextStage
                                )
                                recruitingStage = try? PipelineRepository.shared.fetchRecruitingStage(forPerson: person.id)
                            } label: {
                                Label("Advance", systemImage: "arrow.right.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } else {
                        // No recruiting stage yet — offer to start tracking
                        Button {
                            try? PipelineRepository.shared.upsertRecruitingStage(
                                personID: person.id,
                                stage: .prospect
                            )
                            try? PipelineRepository.shared.recordTransition(
                                personID: person.id,
                                fromStage: "",
                                toStage: RecruitingStageKind.prospect.rawValue,
                                pipelineType: .recruiting
                            )
                            recruitingStage = try? PipelineRepository.shared.fetchRecruitingStage(forPerson: person.id)
                        } label: {
                            Label("Start Tracking", systemImage: "play.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Production Section (Phase S)

    private var productionSection: some View {
        samSection(title: "Production") {
            VStack(alignment: .leading, spacing: 10) {
                // Summary line
                if !productionRecords.isEmpty {
                    let totalPremium = productionRecords.reduce(0) { $0 + $1.annualPremium }
                    HStack {
                        Text("\(productionRecords.count) record\(productionRecords.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(totalPremium, format: .currency(code: "USD"))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }
                }

                // Record list (most recent 5)
                ForEach(productionRecords.prefix(5), id: \.id) { record in
                    HStack(spacing: 8) {
                        Image(systemName: record.productType.icon)
                            .font(.caption)
                            .foregroundStyle(record.productType.color)
                            .frame(width: 16)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.productType.displayName)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(record.carrierName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Text(record.annualPremium, format: .currency(code: "USD"))
                            .font(.caption)
                            .monospacedDigit()

                        // Status badge — tap to advance
                        Button {
                            try? ProductionRepository.shared.advanceStatus(recordID: record.id)
                            productionRecords = (try? ProductionRepository.shared.fetchRecords(forPerson: person.id)) ?? []
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: record.status.icon)
                                    .font(.system(size: 9))
                                Text(record.status.displayName)
                                    .font(.system(size: 10))
                            }
                            .foregroundStyle(record.status.color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(record.status.color.opacity(0.12))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(record.status.next != nil
                              ? "Advance to \(record.status.next!.displayName)"
                              : record.status.displayName)
                    }
                }

                if productionRecords.count > 5 {
                    Text("\(productionRecords.count - 5) more…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Add button
                Button {
                    showingProductionForm = true
                } label: {
                    Label("Add Production", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var channelPreferenceView: some View {
        HStack(spacing: 8) {
            Text("Communication:")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Channel", selection: channelPreferenceBinding) {
                Text("Automatic").tag("")
                ForEach(CommunicationChannel.allCases, id: \.self) { ch in
                    Text(ch.displayName).tag(ch.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)

            if let inferred = person.inferredChannelRawValue,
               let ch = CommunicationChannel(rawValue: inferred),
               person.preferredChannelRawValue == nil {
                Text("(inferred: \(ch.displayName))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var channelPreferenceBinding: Binding<String> {
        Binding(
            get: { person.preferredChannelRawValue ?? "" },
            set: { newValue in
                person.preferredChannelRawValue = newValue.isEmpty ? nil : newValue
            }
        )
    }

    private var cadencePreferenceView: some View {
        HStack(spacing: 8) {
            Text("Cadence:")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Cadence", selection: cadencePreferenceBinding) {
                Text("Automatic").tag(0)
                Text("Weekly").tag(7)
                Text("Every 2 weeks").tag(14)
                Text("Monthly").tag(30)
                Text("Quarterly").tag(90)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)

            if person.preferredCadenceDays == nil {
                let health = MeetingPrepCoordinator.shared.computeHealth(for: person)
                if let computed = health.cadenceDays {
                    Text("(computed: ~\(computed)d)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var cadencePreferenceBinding: Binding<Int> {
        Binding(
            get: { person.preferredCadenceDays ?? 0 },
            set: { newValue in
                person.preferredCadenceDays = newValue == 0 ? nil : newValue
            }
        )
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

            // Recruiting Pipeline (Phase R — shown for Agent badge)
            if person.roleBadges.contains("Agent") {
                recruitingStageSection
            }

            // Production (Phase S — shown for Client or Applicant badge)
            if person.roleBadges.contains("Client") || person.roleBadges.contains("Applicant") {
                productionSection
            }

            // Referred by (Client / Applicant / Lead only)
            if hasReferralRole {
                referredBySection
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
            
            // Relationship Summary (Phase L-2)
            if person.relationshipSummary != nil {
                relationshipSummarySection
            }

            // Notes (Phase L-2)
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
    
    // Relationship Summary section (Phase L-2)
    private var relationshipSummarySection: some View {
        samSection(title: "Relationship Summary") {
            VStack(alignment: .leading, spacing: 8) {
                // Overview
                if let overview = person.relationshipSummary {
                    Text(overview)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                // Key themes as capsule badges
                if !person.relationshipKeyThemes.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(person.relationshipKeyThemes, id: \.self) { theme in
                            Text(theme)
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.purple.opacity(0.1))
                                .foregroundStyle(.purple)
                                .clipShape(Capsule())
                        }
                    }
                }

                // Next steps
                if !person.relationshipNextSteps.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(person.relationshipNextSteps, id: \.self) { step in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "arrow.right.circle")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                                    .padding(.top, 1)
                                Text(step)
                                    .font(.caption)
                            }
                        }
                    }
                }

                // Updated timestamp
                if let updatedAt = person.summaryUpdatedAt {
                    Text("Updated \(updatedAt, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Correction button
                Button {
                    showingCorrectionSheet = true
                } label: {
                    Label("Correct this", systemImage: "pencil.and.list.clipboard")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    // Notes section (Phase L-2)
    private var notesSection: some View {
        samSection(title: "Notes") {
            // Inline capture — always visible
            InlineNoteCaptureView(
                linkedPerson: person,
                linkedContext: nil,
                onSaved: { loadNotes() }
            )
            .padding(.vertical, 4)

            // Scrollable notes journal
            NotesJournalView(
                notes: personNotes,
                onUpdated: { loadNotes() }
            )
        }
    }
    
    // MARK: - Referred By

    private static let referralRoles: Set<String> = ["Client", "Applicant", "Lead"]

    private var hasReferralRole: Bool {
        !person.roleBadges.filter { Self.referralRoles.contains($0) }.isEmpty
    }

    private var referredBySection: some View {
        samSection(title: "Referred by") {
            HStack(spacing: 8) {
                if let referrer = person.referredBy {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.green)

                    Button {
                        NotificationCenter.default.post(
                            name: .samNavigateToPerson,
                            object: nil,
                            userInfo: ["personID": referrer.id]
                        )
                    } label: {
                        Text(referrer.displayNameCache ?? referrer.displayName)
                            .font(.body)
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    // Clear referral
                    Button {
                        person.referredBy = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove referrer")

                    // Change referral
                    Button {
                        showingReferrerPicker = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Change referrer")
                } else {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("No referrer set")
                        .font(.body)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        showingReferrerPicker = true
                    } label: {
                        Label("Set", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 4)
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

// MARK: - Referrer Picker Sheet

private struct ReferrerPickerSheet: View {
    let person: SamPerson
    let candidates: [SamPerson]
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredCandidates: [SamPerson] {
        let sorted = candidates.sorted {
            ($0.displayNameCache ?? $0.displayName)
            < ($1.displayNameCache ?? $1.displayName)
        }
        if searchText.isEmpty { return sorted }
        return sorted.filter {
            ($0.displayNameCache ?? $0.displayName)
                .localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if filteredCandidates.isEmpty {
                    Text("No contacts found")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredCandidates, id: \.id) { candidate in
                        Button {
                            person.referredBy = candidate
                            dismiss()
                        } label: {
                            HStack {
                                Text(candidate.displayNameCache ?? candidate.displayName)
                                    .foregroundStyle(.primary)

                                Spacer()

                                ForEach(candidate.roleBadges.prefix(2), id: \.self) { badge in
                                    let style = RoleBadgeStyle.forBadge(badge)
                                    Text(badge)
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(style.color.opacity(0.15))
                                        .foregroundStyle(style.color)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                }

                                if person.referredBy?.id == candidate.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search contacts")
            .navigationTitle("Select Referrer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 350, minHeight: 300)
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

                // Velocity trend indicator (replaces simple trend when available)
                velocityTrendIndicator
            }

            // Cadence + overdue ratio row (when velocity data available)
            if health.cadenceDays != nil || health.overdueRatio != nil {
                HStack(spacing: 8) {
                    if let cadence = health.cadenceDays {
                        cadenceChip(days: cadence)
                    }
                    if let ratio = health.overdueRatio, ratio >= 1.0 {
                        overdueRatioChip(ratio: ratio)
                    }
                    qualityScoreChip(score: health.qualityScore30)
                }
            }

            // Frequency chips
            HStack(spacing: 8) {
                frequencyChip(label: "30d", count: health.interactionCount30)
                frequencyChip(label: "60d", count: health.interactionCount90 - health.interactionCount30)
                frequencyChip(label: "90d", count: health.interactionCount90)
            }

            // Decay risk badge + predicted overdue (if applicable)
            if health.decayRisk >= .moderate {
                HStack(spacing: 8) {
                    decayRiskBadge
                    if let predicted = health.predictedOverdueDays, predicted > 0 {
                        Text("Predicted overdue in ~\(predicted) day\(predicted == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var velocityTrendIndicator: some View {
        Group {
            if health.cadenceDays != nil {
                // Use velocity trend when we have enough data
                switch health.velocityTrend {
                case .accelerating:
                    Label("Accelerating", systemImage: "arrow.up.right")
                        .foregroundStyle(.green)
                case .steady:
                    Label("Steady", systemImage: "arrow.right")
                        .foregroundStyle(.secondary)
                case .decelerating:
                    Label("Decelerating", systemImage: "arrow.down.right")
                        .foregroundStyle(.orange)
                case .noData:
                    simpleTrendLabel
                }
            } else {
                simpleTrendLabel
            }
        }
        .font(.caption)
    }

    private var simpleTrendLabel: some View {
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
    }

    private func cadenceChip(days: Int) -> some View {
        let label: String
        if days == 1 {
            label = "~every day"
        } else if days == 7 {
            label = "~weekly"
        } else if days >= 13 && days <= 15 {
            label = "~every 2 weeks"
        } else if days >= 28 && days <= 32 {
            label = "~monthly"
        } else {
            label = "~every \(days) days"
        }
        return Text(label)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func overdueRatioChip(ratio: Double) -> some View {
        let formatted: String
        let rounded = (ratio * 10).rounded() / 10
        if rounded == rounded.rounded() {
            formatted = "\(Int(rounded))\u{00D7}"
        } else {
            formatted = String(format: "%.1f\u{00D7}", rounded)
        }
        let color: Color = ratio >= 2.5 ? .red : .orange
        return Text(formatted)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func qualityScoreChip(score: Double) -> some View {
        Text("Q: \(String(format: "%.1f", score))")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var decayRiskBadge: some View {
        let (label, color): (String, Color) = {
            switch health.decayRisk {
            case .moderate: return ("Moderate Risk", .yellow)
            case .high:     return ("High Risk", .orange)
            case .critical: return ("Critical", .red)
            default:        return ("", .clear)
            }
        }()
        if !label.isEmpty {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(color.opacity(0.12))
                .clipShape(Capsule())
        }
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
