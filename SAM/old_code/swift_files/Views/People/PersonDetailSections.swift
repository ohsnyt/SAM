//
//  PersonDetailSections.swift
//  SAM_crm
//
//  UI sections for the Contacts-rich person detail view.
//  Displays family, contact info, professional details, and summary notes
//  from Apple Contacts (via ContactSyncService).
//

import SwiftUI
import Contacts

// MARK: - Family Section

struct FamilySection: View {
    let contact: CNContact
    let person: SamPerson
    
    @State private var showingError: String?
    @State private var showingSuccess: String?
    
    var body: some View {
        GroupBox("Family & Relationships") {
            VStack(alignment: .leading, spacing: 12) {
                // Spouse/Partner
                if let spouse = contact.contactRelations.first(where: {
                    $0.label == CNLabelContactRelationSpouse ||
                    $0.label == CNLabelContactRelationPartner
                }) {
                    RelationRow(
                        icon: "heart.fill",
                        label: localizedLabel(spouse.label),
                        name: spouse.value.name,
                        action: { openOrSearchContact(name: spouse.value.name) }
                    )
                }
                
                // Children
                let children = contact.contactRelations.filter {
                    $0.label == CNLabelContactRelationChild ||
                    $0.label == CNLabelContactRelationDaughter ||
                    $0.label == CNLabelContactRelationSon
                }
                
                if !children.isEmpty {
                    Text("Children")
                        .font(.headline)
                        .padding(.top, 4)
                    
                    ForEach(children, id: \.identifier) { child in
                        RelationRow(
                            icon: "person.fill",
                            label: localizedLabel(child.label),
                            name: child.value.name,
                            action: { openOrSearchContact(name: child.value.name) }
                        )
                    }
                }
                
                // Parents
                let parents = contact.contactRelations.filter {
                    $0.label == CNLabelContactRelationParent ||
                    $0.label == CNLabelContactRelationMother ||
                    $0.label == CNLabelContactRelationFather
                }
                
                if !parents.isEmpty {
                    Text("Parents")
                        .font(.headline)
                        .padding(.top, 4)
                    
                    ForEach(parents, id: \.identifier) { parent in
                        RelationRow(
                            icon: "person.2.fill",
                            label: localizedLabel(parent.label),
                            name: parent.value.name,
                            action: { openOrSearchContact(name: parent.value.name) }
                        )
                    }
                }
                
                // Birthday
                if let birthday = contact.birthday {
                    Divider()
                        .padding(.vertical, 4)
                    
                    HStack {
                        Image(systemName: "gift.fill")
                            .foregroundStyle(.secondary)
                        Text("Birthday: \(formatBirthday(birthday))")
                            .font(.callout)
                    }
                }
                
                // Anniversary
                if let anniversary = contact.dates.first(where: {
                    $0.label == CNLabelDateAnniversary
                }) {
                    HStack {
                        Image(systemName: "calendar.badge.clock")
                            .foregroundStyle(.secondary)
                        Text("Anniversary: \(formatDate(anniversary.value as DateComponents))")
                            .font(.callout)
                    }
                }
                
                // Actions
                HStack(spacing: 8) {
                    Button {
                        openInContacts(person.contactIdentifier)
                    } label: {
                        Label("Edit in Contacts", systemImage: "person.crop.circle.badge.pencil")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 8)
                
                // Success/Error messages
                if let success = showingSuccess {
                    Text(success)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                
                if let error = showingError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.vertical, 6)
        }
    }
    
    private func localizedLabel(_ label: String?) -> String {
        guard let label else { return "Relation" }
        return CNLabeledValue<NSString>.localizedString(forLabel: label)
    }
    
    private func formatBirthday(_ components: DateComponents) -> String {
        let calendar = Calendar.current
        guard let date = calendar.date(from: components) else {
            return "Unknown"
        }
        
        let formatter = DateFormatter()
        if components.year != nil {
            formatter.dateStyle = .medium
        } else {
            // No year - just month and day
            formatter.dateFormat = "MMMM d"
        }
        return formatter.string(from: date)
    }
    
    private func formatDate(_ components: DateComponents) -> String {
        let calendar = Calendar.current
        guard let date = calendar.date(from: components) else {
            return "Unknown"
        }
        
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
    
    private func openInContacts(_ identifier: String?) {
        guard let identifier else { return }
        
        #if os(macOS)
        // Use addressbook:// URL scheme to open specific contact
        if let url = URL(string: "addressbook://\(identifier)") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
    
    private func openOrSearchContact(name: String) {
        // For now, just open Contacts app
        // TODO: Search for contact by name, open if found, create if not
        #if os(macOS)
        let url = URL(fileURLWithPath: "/System/Applications/Contacts.app")
        NSWorkspace.shared.open(url)
        #endif
    }
}

struct RelationRow: View {
    let icon: String
    let label: String
    let name: String
    let action: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.callout)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button {
                action()
            } label: {
                Image(systemName: "arrow.forward.circle.fill")
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .help("View contact")
        }
    }
}

// MARK: - Contact Info Section

struct ContactInfoSection: View {
    let contact: CNContact
    
    var body: some View {
        GroupBox("Contact Information") {
            VStack(alignment: .leading, spacing: 8) {
                // Phone numbers
                if !contact.phoneNumbers.isEmpty {
                    ForEach(contact.phoneNumbers, id: \.identifier) { phone in
                        ContactItemRow(
                            icon: "phone.fill",
                            value: phone.value.stringValue,
                            label: localizedLabel(phone.label),
                            actionIcon: "phone.circle.fill",
                            action: {
                                #if os(macOS)
                                let cleaned = phone.value.stringValue.filter { "0123456789".contains($0) }
                                if let url = URL(string: "tel:\(cleaned)") {
                                    NSWorkspace.shared.open(url)
                                }
                                #endif
                            }
                        )
                    }
                }
                
                // Email addresses
                if !contact.emailAddresses.isEmpty {
                    if !contact.phoneNumbers.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                    }
                    
                    ForEach(contact.emailAddresses, id: \.identifier) { email in
                        ContactItemRow(
                            icon: "envelope.fill",
                            value: email.value as String,
                            label: localizedLabel(email.label),
                            actionIcon: "envelope.circle.fill",
                            action: {
                                #if os(macOS)
                                if let url = URL(string: "mailto:\(email.value)") {
                                    NSWorkspace.shared.open(url)
                                }
                                #endif
                            }
                        )
                    }
                }
                
                // Postal addresses
                if !contact.postalAddresses.isEmpty {
                    if !contact.phoneNumbers.isEmpty || !contact.emailAddresses.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                    }
                    
                    ForEach(contact.postalAddresses, id: \.identifier) { address in
                        let addressString = CNPostalAddressFormatter.string(
                            from: address.value,
                            style: .mailingAddress
                        )
                        
                        ContactItemRow(
                            icon: "mappin.circle.fill",
                            value: addressString,
                            label: localizedLabel(address.label),
                            actionIcon: "map.circle.fill",
                            action: {
                                #if os(macOS)
                                let encoded = addressString.addingPercentEncoding(
                                    withAllowedCharacters: .urlQueryAllowed
                                ) ?? ""
                                if let url = URL(string: "http://maps.apple.com/?address=\(encoded)") {
                                    NSWorkspace.shared.open(url)
                                }
                                #endif
                            }
                        )
                    }
                }
                
                // URLs
                if !contact.urlAddresses.isEmpty {
                    if !contact.phoneNumbers.isEmpty || !contact.emailAddresses.isEmpty || !contact.postalAddresses.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                    }
                    
                    ForEach(contact.urlAddresses, id: \.identifier) { urlAddress in
                        ContactItemRow(
                            icon: "link.circle.fill",
                            value: urlAddress.value as String,
                            label: localizedLabel(urlAddress.label),
                            actionIcon: "arrow.up.right.circle.fill",
                            action: {
                                #if os(macOS)
                                if let url = URL(string: urlAddress.value as String) {
                                    NSWorkspace.shared.open(url)
                                }
                                #endif
                            }
                        )
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }
    
    private func localizedLabel(_ label: String?) -> String {
        guard let label else { return "" }
        return CNLabeledValue<NSString>.localizedString(forLabel: label)
    }
}

struct ContactItemRow: View {
    let icon: String
    let value: String
    let label: String
    let actionIcon: String
    let action: () -> Void
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.callout)
                    .textSelection(.enabled)
                if !label.isEmpty {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            Button {
                action()
            } label: {
                Image(systemName: actionIcon)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .help("Open")
        }
    }
}

// MARK: - Professional Section

struct ProfessionalSection: View {
    let contact: CNContact
    
    var hasInfo: Bool {
        !contact.organizationName.isEmpty ||
        !contact.jobTitle.isEmpty ||
        !contact.departmentName.isEmpty
    }
    
    var body: some View {
        if hasInfo {
            GroupBox("Professional") {
                VStack(alignment: .leading, spacing: 8) {
                    if !contact.organizationName.isEmpty {
                        InfoRow(icon: "building.2.fill", label: "Company", value: contact.organizationName)
                    }
                    
                    if !contact.jobTitle.isEmpty {
                        InfoRow(icon: "briefcase.fill", label: "Title", value: contact.jobTitle)
                    }
                    
                    if !contact.departmentName.isEmpty {
                        InfoRow(icon: "person.3.fill", label: "Department", value: contact.departmentName)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

struct InfoRow: View {
    let icon: String
    let label: String
    let value: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout)
            }
            
            Spacer()
        }
    }
}

// MARK: - Summary Note Section

struct SummaryNoteSection: View {
    let contact: CNContact
    let person: SamPerson
    
    @State private var showAISuggestion = false
    @State private var suggestedNote = ""
    @State private var isGenerating = false
    @State private var showError: String?
    
    // Feature flag: matches ContactSyncService
    private let hasNotesEntitlement = false
    
    var body: some View {
        GroupBox("Summary") {
            VStack(alignment: .leading, spacing: 12) {
                if hasNotesEntitlement {
                    // TODO: Enable when Notes entitlement is granted
                    if !contact.note.isEmpty {
                        ScrollView {
                            Text(contact.note)
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 200)
                    } else {
                        Text("No summary yet")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                            .italic()
                    }
                } else {
                    // Development mode: Show placeholder
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "note.text")
                                .foregroundStyle(.orange)
                            Text("Notes Access Pending")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                        Text("Contact notes will appear here once Apple grants the Notes entitlement. For now, AI-generated notes will be logged to the console.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(.orange.opacity(0.1))
                    .cornerRadius(8)
                }
                
                HStack(spacing: 8) {
                    Button {
                        Task {
                            isGenerating = true
                            suggestedNote = await generateSummary(for: person)
                            isGenerating = false
                            showAISuggestion = true
                        }
                    } label: {
                        if isGenerating {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 16, height: 16)
                            Text("Generating...")
                        } else {
                            Label("Suggest AI Update", systemImage: "sparkles")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isGenerating)
                    
                    Button {
                        openInContacts(person.contactIdentifier)
                    } label: {
                        Label("Edit in Contacts", systemImage: "pencil")
                    }
                    .buttonStyle(.bordered)
                }
                
                if let error = showError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.vertical, 6)
        }
        .sheet(isPresented: $showAISuggestion) {
            AISummaryApprovalSheet(
                suggestedNote: $suggestedNote,
                person: person,
                onApprove: {
                    do {
                        try ContactSyncService.shared.updateSummaryNote(suggestedNote, for: person)
                        showAISuggestion = false
                        if hasNotesEntitlement {
                            showError = nil
                        } else {
                            // Show success message in development mode
                            showError = nil
                            print("✅ [SummaryNoteSection] AI note approved and logged. Check console for note content.")
                        }
                    } catch {
                        showError = error.localizedDescription
                    }
                },
                onCancel: {
                    showAISuggestion = false
                }
            )
        }
    }
    
    private func generateSummary(for person: SamPerson) async -> String {
        // TODO: Call LLM to generate summary from:
        // - Recent evidence
        // - Insights
        // - Coverage data
        // - Family info from CNContact
        
        // For now, return placeholder
        return """
        Client relationship active since \(person.lastSyncedAt?.formatted(date: .abbreviated, time: .omitted) ?? "recently").
        
        [AI would summarize recent interactions, coverage, and opportunities here]
        """
    }
    
    private func openInContacts(_ identifier: String?) {
        guard let identifier else { return }
        
        #if os(macOS)
        if let url = URL(string: "addressbook://\(identifier)") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}

struct AISummaryApprovalSheet: View {
    @Binding var suggestedNote: String
    let person: SamPerson
    let onApprove: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Text("AI-Generated Summary")
                .font(.headline)
            
            Text("Review and edit the suggested summary before adding to \(person.displayNameCache ?? "contact")'s Contacts record.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            TextEditor(text: $suggestedNote)
                .font(.callout)
                .frame(height: 200)
                .border(Color.secondary.opacity(0.3), width: 1)
            
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape)
                
                Spacer()
                
                Button("Add to Contacts", action: onApprove)
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 500)
    }
}
