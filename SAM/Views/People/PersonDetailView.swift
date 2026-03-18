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
import TipKit
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "PersonDetailView")

struct PersonDetailView: View {
    
    // MARK: - Properties
    
    let person: SamPerson
    
    // MARK: - Dependencies

    @Environment(\.modelContext) private var modelContext
    @State private var contactsService = ContactsService.shared
    @State private var notesRepository = NotesRepository.shared
    @State private var enrichmentCoordinator = ContactEnrichmentCoordinator.shared
    
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
    @State private var pendingEnrichments: [PendingEnrichment] = []
    @State private var showingEnrichmentSheet = false
    @State private var showingLifecycleConfirm = false
    @State private var pendingLifecycleStatus: ContactLifecycleStatus?
    @State private var roleDeductionEngine = RoleDeductionEngine.shared
    @State private var photoCoordinator = ContactPhotoCoordinator.shared
    @State private var isPhotoDropTargeted = false
    @State private var photoViewScreenOrigin: CGPoint?
    @State private var photoLinks = ContactPhotoCoordinator.ProfileLinks(linkedIn: nil, facebook: nil)

    @Query(filter: #Predicate<SamPerson> { $0.lifecycleStatusRawValue == "active" })
    private var allPeople: [SamPerson]

    // MARK: - Cached Health

    /// Computed once per view evaluation to avoid redundant `computeHealth(for:)` calls.
    private var personHealth: RelationshipHealth {
        MeetingPrepCoordinator.shared.computeHealth(for: person)
    }

    // MARK: - Body

    @State private var showMoreDetails = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Above-the-fold: photo, name, health, recommendation, quick actions, primary contact
                headerSection
                    .padding(.horizontal)
                    .padding(.top)

                // Enrichment banner
                if !pendingEnrichments.isEmpty {
                    enrichmentBanner
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }

                // Loading state
                if isLoadingContact {
                    HStack {
                        ProgressView()
                        Text("Loading contact details...")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }

                // Error state for contacts
                if !isLoadingContact && person.contactIdentifier != nil && fullContact == nil {
                    errorStateSection
                        .padding()
                }

                // Primary sections (visible by default)
                primarySections

                // More Details (collapsed by default)
                moreDetailsSection
            }
        }
        .focusable(false)  // Prevent ScrollView stealing first click on macOS
        .navigationTitle("")  // Remove title since we show it in the header
        .toolbar {
            ToolbarItem {
                Divider()
                    .frame(height: 20)
            }
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
                
                Button {
                    viewInGraph()
                } label: {
                    Label("View in Graph", systemImage: "circle.grid.cross")
                }
                .help("Show this person in the Relationship Map")

                Menu {
                    Button("Add to Context", systemImage: "building.2") {
                        showingContextPicker = true
                    }

                    Divider()

                    // Lifecycle submenu
                    Menu("Lifecycle") {
                        if person.lifecycleStatus == .active {
                            Button("Archive", systemImage: "archivebox") {
                                pendingLifecycleStatus = .archived
                                showingLifecycleConfirm = true
                            }
                            Button("Mark Do Not Contact", systemImage: "hand.raised") {
                                pendingLifecycleStatus = .dnc
                                showingLifecycleConfirm = true
                            }
                            Button("Mark Deceased", systemImage: "heart.slash") {
                                pendingLifecycleStatus = .deceased
                                showingLifecycleConfirm = true
                            }
                        } else {
                            Button("Reactivate", systemImage: "arrow.uturn.backward") {
                                applyLifecycleChange(.active)
                            }
                        }
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
            // Set initial links from SamPerson fields (available immediately)
            photoLinks = photoCoordinator.profileLinks(for: person)
            await loadFullContact()
            loadNotes()
            recruitingStage = try? PipelineRepository.shared.fetchRecruitingStage(forPerson: person.id)
            productionRecords = (try? ProductionRepository.shared.fetchRecords(forPerson: person.id)) ?? []
            visibleInteractionCount = 3
            pendingEnrichments = enrichmentCoordinator.pendingEnrichments(for: person.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .samUndoDidRestore)) { _ in
            loadNotes()
        }
        .sheet(isPresented: $showingEnrichmentSheet, onDismiss: {
            pendingEnrichments = enrichmentCoordinator.pendingEnrichments(for: person.id)
            // Re-fetch contact data so updated company/job title appear immediately
            Task { await loadFullContact() }
        }) {
            EnrichmentReviewSheet(person: person, enrichments: pendingEnrichments)
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
        .alert(
            "Change Lifecycle Status",
            isPresented: $showingLifecycleConfirm,
            presenting: pendingLifecycleStatus
        ) { status in
            Button("Cancel", role: .cancel) {
                pendingLifecycleStatus = nil
            }
            Button(status.displayName, role: status == .active ? nil : .destructive) {
                applyLifecycleChange(status)
                pendingLifecycleStatus = nil
            }
        } message: { status in
            switch status {
            case .archived:
                Text("Archive \(person.displayNameCache ?? person.displayName)? They won't appear in suggestions.")
            case .dnc:
                Text("Mark \(person.displayNameCache ?? person.displayName) as Do Not Contact? No outreach will be generated.")
            case .deceased:
                Text("Mark \(person.displayNameCache ?? person.displayName) as deceased? Their record will be preserved but excluded from all outreach.")
            case .active:
                Text("Reactivate \(person.displayNameCache ?? person.displayName)?")
            }
        }
    }
    
    private let personCoachingTip = PersonCoachingTip()

    // MARK: - Enrichment Banner

    private var enrichmentBanner: some View {
        Button {
            showingEnrichmentSheet = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(.blue)
                let count = pendingEnrichments.count
                Text("\(count) contact update\(count == 1 ? "" : "s") available")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.blue.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.blue.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Header Section (Above the Fold)

    // MARK: - Contact Photo (Drop Target)

    private var contactPhotoView: some View {
        let links = photoLinks
        let hasPhoto = person.photoThumbnailCache != nil
        let isClickable = !hasPhoto && !links.isEmpty

        return Group {
            if let photoData = person.photoThumbnailCache,
               let nsImage = NSImage(data: photoData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                let initials = personInitials
                let color = person.roleBadges.first.map { RoleBadgeStyle.forBadge($0).color } ?? .secondary
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(color.opacity(0.15))
                        .frame(width: 96, height: 96)
                    VStack(spacing: 4) {
                        Text(initials)
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(color)
                        if !links.isEmpty {
                            Image(systemName: "photo.badge.plus")
                                .font(.caption2)
                                .foregroundStyle(color.opacity(0.6))
                        }
                    }
                }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .background {
            GeometryReader { geo in
                Color.clear.onAppear {
                    // Convert to screen coordinates (flipped: top-left origin for AppleScript)
                    if let window = NSApp.keyWindow {
                        let frameInWindow = geo.frame(in: .global)
                        let windowOrigin = window.frame.origin
                        let screenFrame = window.screen?.frame ?? NSScreen.main!.frame
                        // SwiftUI .global is window-relative with flipped Y; convert to screen top-left
                        let screenX = windowOrigin.x + frameInWindow.minX
                        let screenY = screenFrame.height - (windowOrigin.y + window.frame.height) + frameInWindow.minY
                        photoViewScreenOrigin = CGPoint(x: screenX, y: screenY)
                    }
                }
            }
        }
        .onTapGesture {
            if isClickable {
                photoCoordinator.openProfileForPhotoGrab(person: person, photoScreenOrigin: photoViewScreenOrigin)
            }
        }
        .help(isClickable ? "Click to open profile for photo" : "Drag & drop a photo here")
        .overlay {
            if isPhotoDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        VStack(spacing: 4) {
                            Image(systemName: "photo.badge.plus")
                                .font(.title2)
                            Text("Drop")
                                .font(.caption)
                        }
                        .foregroundStyle(.primary)
                    }
            }
            if photoCoordinator.isSaving {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .overlay { ProgressView() }
            }
        }
        .overlay(alignment: .bottom) {
            if let error = photoCoordinator.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.red.opacity(0.85), in: Capsule())
                    .offset(y: 20)
                    .transition(.opacity)
            }
        }
        .animation(.default, value: photoCoordinator.errorMessage != nil)
        .animation(.default, value: isPhotoDropTargeted)
        .onDrop(of: [.image, .url], isTargeted: $isPhotoDropTargeted) { providers in
            photoCoordinator.handleDrop(providers: providers, for: person)
            return true
        }
        .contextMenu {
            if ImagePasteUtility.pasteboardHasImageOnly() {
                Button("Paste Photo") {
                    Task { await photoCoordinator.handlePaste(for: person) }
                }
            }
            if !links.isEmpty {
                Divider()
                if let li = links.linkedIn {
                    Button("Open LinkedIn for Photo") {
                        photoCoordinator.openURL(url: li, photoScreenOrigin: photoViewScreenOrigin)
                    }
                }
                if let fb = links.facebook {
                    Button("Open Facebook for Photo") {
                        photoCoordinator.openURL(url: fb, photoScreenOrigin: photoViewScreenOrigin)
                    }
                }
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TipView(personCoachingTip)
                .tipViewStyle(SAMTipViewStyle())

            // Row 1: Photo + Name + Company + Role Badges
            HStack(alignment: .top, spacing: 16) {
                // Photo (96pt, full opacity, rounded corners) — drop target for contact photo
                contactPhotoView

                VStack(alignment: .leading, spacing: 4) {
                    Text(person.displayNameCache ?? person.displayName)
                        .font(.system(size: 28, weight: .bold))

                    if let contact = fullContact {
                        if !contact.organizationName.isEmpty {
                            HStack(spacing: 4) {
                                Text(contact.organizationName)
                                    .font(.body)
                                if !contact.jobTitle.isEmpty {
                                    Text("•")
                                        .foregroundStyle(.secondary)
                                    Text(contact.jobTitle)
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else if !contact.jobTitle.isEmpty {
                            Text(contact.jobTitle)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Role badges
                    roleBadgesView
                }

                Spacer()
            }

            // Row 2: Health status sentence
            if !person.isMe {
                healthStatusText
            }

            // Row 3: Top recommendation card (if exists)
            if let outcome = OutcomeRepository.shared.fetchTopActiveOutcome(forPersonID: person.id) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SAM recommends")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.blue)
                        .textCase(.uppercase)

                    Text(outcome.title)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text(outcome.rationale)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                )
            }

            // Row 4: Quick actions
            quickActionsRow

            // Row 5: Primary contact info
            if let contact = fullContact {
                primaryContactInfo(contact)
            }
        }
        .padding(.bottom, 16)
    }

    private var personInitials: String {
        let name = person.displayNameCache ?? person.displayName
        let words = name.split(separator: " ")
        let chars = words.prefix(2).compactMap(\.first)
        return String(chars).uppercased()
    }

    private var healthStatusText: some View {
        let health = personHealth
        return HStack(spacing: 6) {
            Circle()
                .fill(health.statusColor)
                .frame(width: 8, height: 8)

            if let days = health.daysSinceLastInteraction {
                switch health.decayRisk {
                case .none, .low:
                    Text("Healthy — last spoke \(days) days ago")
                case .moderate:
                    Text("Needs attention — \(days) days since last contact")
                case .high, .critical:
                    Text("At risk — \(days) days since last contact")
                }
            } else {
                Text("No interaction history")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    // MARK: - Evidence-Gated Social Actions

    private struct SocialAction: Identifiable {
        let id = UUID()
        let label: String
        let icon: String
        let url: String
        let isLinkedIn: Bool
    }

    private var evidenceBackedSocialActions: [SocialAction] {
        let evidenceSources = Set(person.linkedEvidence.map(\.source))
        var actions: [SocialAction] = []

        if evidenceSources.contains(.linkedIn) {
            if let url = person.linkedInProfileURL.flatMap({ $0.isEmpty ? nil : $0 }) ?? contactLinkedInURL {
                actions.append(SocialAction(label: "LinkedIn", icon: "network", url: url, isLinkedIn: true))
            }
        }

        if evidenceSources.contains(.facebook) {
            if let url = person.facebookProfileURL.flatMap({ $0.isEmpty ? nil : $0 }) ?? contactFacebookURL {
                actions.append(SocialAction(label: "Facebook", icon: "person.2.fill", url: url, isLinkedIn: false))
            }
        }

        return actions
    }

    private var contactLinkedInURL: String? {
        guard let profile = fullContact?.socialProfiles.first(where: {
            $0.service.lowercased() == "linkedin" ||
            ($0.urlString ?? "").lowercased().contains("linkedin.com/in/")
        }) else { return nil }
        if let url = profile.urlString, !url.isEmpty { return url }
        if !profile.username.isEmpty {
            // username may already be a URL path like "www.linkedin.com/in/jsmith"
            if profile.username.lowercased().contains("linkedin.com/in/") {
                return profile.username
            }
            return "https://www.linkedin.com/in/\(profile.username)"
        }
        return nil
    }

    private var contactFacebookURL: String? {
        guard let profile = fullContact?.socialProfiles.first(where: {
            $0.service.lowercased() == "facebook" ||
            ($0.urlString ?? "").lowercased().contains("facebook.com/")
        }) else { return nil }
        if let url = profile.urlString, !url.isEmpty { return url }
        if !profile.username.isEmpty {
            if profile.username.lowercased().contains("facebook.com/") {
                return profile.username
            }
            return "https://www.facebook.com/\(profile.username)"
        }
        return nil
    }

    private var quickActionsRow: some View {
        HStack(spacing: 8) {
            if let contact = fullContact, let phone = contact.phoneNumbers.first {
                Button {
                    let number = phone.number.replacingOccurrences(of: " ", with: "")
                    if let url = URL(string: "sms:\(number)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Text", systemImage: "message")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    if let url = URL(string: "tel:\(phone.number.replacingOccurrences(of: " ", with: ""))") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Call", systemImage: "phone")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let contact = fullContact, let email = contact.emailAddresses.first {
                Button {
                    if let url = URL(string: "mailto:\(email)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Email", systemImage: "envelope")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            ForEach(evidenceBackedSocialActions) { action in
                Button {
                    if action.isLinkedIn {
                        ComposeService.shared.openLinkedInMessaging(profileURL: action.url)
                    } else {
                        ComposeService.shared.openSocialProfile(url: action.url)
                    }
                } label: {
                    Label(action.label, systemImage: action.icon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()
        }
    }

    private func primaryContactInfo(_ contact: ContactDTO) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let phone = contact.phoneNumbers.first {
                HStack(spacing: 4) {
                    Image(systemName: "phone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(phone.number)
                        .font(.subheadline)
                    if let label = phone.label, !label.isEmpty {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let email = contact.emailAddresses.first {
                HStack(spacing: 4) {
                    Image(systemName: "envelope")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(email)
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                }
            }
        }
    }
    
    // MARK: - Role Badges

    private static let builtInBadges = [
        "Client", "Applicant", "Lead", "Vendor",
        "Agent", "External Agent", "Referral Partner"
    ]

    /// Built-in badges + any user-defined RoleDefinition names (deduplicated, stable order).
    private var predefinedBadges: [String] {
        let roleNames = (try? RoleRecruitingRepository.shared.fetchActiveRoles().map(\.name)) ?? []
        var seen = Set<String>()
        var result: [String] = []
        for badge in Self.builtInBadges + roleNames {
            if seen.insert(badge).inserted {
                result.append(badge)
            }
        }
        return result
    }

    private var roleBadgesView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // Me badge (non-editable, set via Apple Contacts)
                if person.isMe {
                    Text("Me")
                        .font(.subheadline)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.secondary.opacity(0.2))
                        .foregroundStyle(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                // Placeholder when no roles assigned
                if person.roleBadges.isEmpty && !person.isMe && !isEditingBadges {
                    Text("Add a role")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .italic()
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
                            .font(.subheadline)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(style.color.opacity(0.15))
                            .foregroundStyle(style.color)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }

                // Suggested role badge (pulsing)
                if !isEditingBadges, let suggestion = roleDeductionEngine.suggestion(for: person.id) {
                    RoleSuggestionBadge(
                        suggestion: suggestion,
                        onConfirm: {
                            roleDeductionEngine.confirmRole(personID: person.id, role: suggestion.suggestedRole)
                        },
                        onDismiss: {
                            roleDeductionEngine.dismissSuggestion(personID: person.id)
                        }
                    )
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
                let available = predefinedBadges.filter { !person.roleBadges.contains($0) }
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
        // Auto-assign Prospect recruiting stage when Agent role is added
        if person.roleBadges.contains("Agent"), recruitingStage == nil {
            do {
                try PipelineRepository.shared.upsertRecruitingStage(
                    personID: person.id,
                    stage: .prospect
                )
                try PipelineRepository.shared.recordTransition(
                    personID: person.id,
                    fromStage: "",
                    toStage: RecruitingStageKind.prospect.rawValue,
                    pipelineType: .recruiting
                )
                recruitingStage = try PipelineRepository.shared.fetchRecruitingStage(forPerson: person.id)
            } catch {}
        }
        try? modelContext.save()
        NotificationCenter.default.post(name: .samPersonDidChange, object: nil)
    }

    /// Record client pipeline transitions when role badges change.
    private func recordPipelineTransitions(added: Set<String>, removed: Set<String>) {
        let clientStages: Set<String> = ["Lead", "Applicant", "Client"]

        // For each added client-pipeline badge, record a transition
        for badge in added where clientStages.contains(badge) {
            // Find the removed client badge as the "from" stage, or "" if none
            let fromStage = removed.first(where: { clientStages.contains($0) }) ?? ""
            do {
                try PipelineRepository.shared.recordTransition(
                    personID: person.id,
                    fromStage: fromStage,
                    toStage: badge,
                    pipelineType: .client
                )
            } catch {}
        }

        // For each removed client badge with no replacement, record exit
        let addedClient = added.intersection(clientStages)
        for badge in removed where clientStages.contains(badge) && addedClient.isEmpty {
            do {
                try PipelineRepository.shared.recordTransition(
                    personID: person.id,
                    fromStage: badge,
                    toStage: "",
                    pipelineType: .client
                )
            } catch {}
        }
    }

    // MARK: - Channel Preference

    // MARK: - Recruiting Stage Section

    @State private var showRecruitingRegressionAlert = false
    @State private var pendingRecruitingStage: RecruitingStageKind?

    private var recruitingStageSection: some View {
        samSection(title: "Recruiting Pipeline") {
            VStack(alignment: .leading, spacing: 10) {
                // Stage selector — tap any stage to set it
                HStack(spacing: 0) {
                    ForEach(RecruitingStageKind.allCases, id: \.rawValue) { kind in
                        let isCurrent = recruitingStage?.stage == kind
                        let isReached = (recruitingStage?.stage.order ?? -1) >= kind.order

                        Button {
                            selectRecruitingStage(kind)
                        } label: {
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
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

            }
            .alert("Move to Earlier Stage?", isPresented: $showRecruitingRegressionAlert) {
                Button("Cancel", role: .cancel) {
                    pendingRecruitingStage = nil
                }
                if let pending = pendingRecruitingStage {
                    Button("Move to \(pending.rawValue)") {
                        applyRecruitingStage(pending)
                        pendingRecruitingStage = nil
                    }
                }
            } message: {
                if let pending = pendingRecruitingStage, let current = recruitingStage?.stage {
                    Text("This will move \(person.displayNameCache ?? person.displayName) from \(current.rawValue) back to \(pending.rawValue).")
                }
            }
        }
    }

    private func selectRecruitingStage(_ kind: RecruitingStageKind) {
        let currentOrder = recruitingStage?.stage.order ?? -1

        if kind.order < currentOrder {
            // Going backwards — confirm
            pendingRecruitingStage = kind
            showRecruitingRegressionAlert = true
        } else if kind.order > currentOrder {
            // Going forwards — apply directly
            applyRecruitingStage(kind)
        }
        // Same stage — do nothing
    }

    private func applyRecruitingStage(_ kind: RecruitingStageKind) {
        try? PipelineRepository.shared.advanceRecruitingStage(
            personID: person.id,
            to: kind
        )
        recruitingStage = try? PipelineRepository.shared.fetchRecruitingStage(forPerson: person.id)
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
        VStack(alignment: .leading, spacing: 6) {
            categoryChannelRow(
                category: .quick,
                explicitBinding: channelBinding(
                    get: { person.preferredQuickChannelRawValue },
                    set: { person.preferredQuickChannelRawValue = $0 }
                ),
                inferred: person.inferredQuickChannelRawValue
            )
            categoryChannelRow(
                category: .detailed,
                explicitBinding: channelBinding(
                    get: { person.preferredDetailedChannelRawValue },
                    set: { person.preferredDetailedChannelRawValue = $0 }
                ),
                inferred: person.inferredDetailedChannelRawValue
            )
            categoryChannelRow(
                category: .social,
                explicitBinding: channelBinding(
                    get: { person.preferredSocialChannelRawValue },
                    set: { person.preferredSocialChannelRawValue = $0 }
                ),
                inferred: person.inferredSocialChannelRawValue
            )
        }
    }

    private func categoryChannelRow(
        category: MessageCategory,
        explicitBinding: Binding<String>,
        inferred: String?
    ) -> some View {
        HStack(spacing: 6) {
            Label(category.displayName, systemImage: category.icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            Picker(category.displayName, selection: explicitBinding) {
                Text("Auto").tag("")
                ForEach(CommunicationChannel.allCases, id: \.self) { ch in
                    Text(ch.displayName).tag(ch.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)

            if let raw = inferred,
               let ch = CommunicationChannel(rawValue: raw),
               explicitBinding.wrappedValue.isEmpty {
                Text("(inferred: \(ch.displayName))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func channelBinding(
        get: @escaping () -> String?,
        set: @escaping (String?) -> Void
    ) -> Binding<String> {
        Binding(
            get: { get() ?? "" },
            set: { newValue in set(newValue.isEmpty ? nil : newValue) }
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
                if let computed = personHealth.cadenceDays {
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
            // Include person.linkedInProfileURL even if not yet synced to Apple Contacts social profiles
            let samLinkedInURL = person.linkedInProfileURL
            let linkedInAlreadyInContacts = contact.socialProfiles.contains(where: {
                $0.service.lowercased() == "linkedin" ||
                ($0.urlString ?? "").lowercased().contains("linkedin.com/in/")
            })
            let showSAMLinkedIn = samLinkedInURL != nil && !linkedInAlreadyInContacts

            if !contact.urlAddresses.isEmpty || !contact.socialProfiles.isEmpty || showSAMLinkedIn {
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

                    // Social profiles from Apple Contacts
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

                    // LinkedIn URL from SAM (not yet written back to Contacts)
                    if showSAMLinkedIn, let linkedInURL = samLinkedInURL {
                        let fullURL = linkedInURL.hasPrefix("http") ? linkedInURL : "https://\(linkedInURL)"
                        contactRow(
                            value: linkedInURL,
                            label: "linkedin",
                            action: {
                                if let url = URL(string: fullURL) {
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
    // MARK: - Primary Sections (visible by default)

    private var primarySections: some View {
        VStack(spacing: 0) {
            // Notes — most used section, shown first
            notesSection

            // Interaction History — all linked evidence interactions
            if !person.isMe {
                interactionHistorySection
            }

            // Social Platforms — LinkedIn & Facebook connection metadata
            if !person.isMe && hasSocialPlatformData {
                socialPlatformSection
            }

            // Recruiting Pipeline (Agent badge)
            if person.roleBadges.contains("Agent") {
                recruitingStageSection
            }

            // Production (Client or Applicant badge)
            if person.roleBadges.contains("Client") || person.roleBadges.contains("Applicant") {
                productionSection
            }

            // Relationship Summary
            if person.relationshipSummary != nil {
                relationshipSummarySection
            }

            // Family & Relationships (note-discovered)
            if !person.familyReferences.isEmpty {
                familyReferencesSection
            }
        }
    }

    // MARK: - Family & Relationships

    private var familyReferencesSection: some View {
        samSection(title: "Family & Relationships") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(person.familyReferences) { ref in
                    HStack(spacing: 8) {
                        Image(systemName: ref.linkedPersonID != nil ? "person.fill" : "person.fill.questionmark")
                            .font(.caption)
                            .foregroundStyle(ref.linkedPersonID != nil ? .green : .secondary)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(ref.name)
                                .font(.body)
                            Text(ref.relationship.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if ref.linkedPersonID == nil {
                            Text("No contact")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 4)

                    if ref.id != person.familyReferences.last?.id {
                        Divider()
                            .padding(.leading, 28)
                    }
                }
            }
        }
    }

    // MARK: - Interaction History

    @State private var visibleInteractionCount = 3

    private var interactionHistorySection: some View {
        let interactions = person.linkedEvidence
            .filter { $0.source.isInteraction }
            .sorted { $0.occurredAt > $1.occurredAt }

        guard !interactions.isEmpty else { return AnyView(EmptyView()) }

        let visibleItems = Array(interactions.prefix(visibleInteractionCount))
        let remaining = interactions.count - visibleInteractionCount

        return AnyView(samSection(title: "Interaction History") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(visibleItems, id: \.id) { item in
                    interactionRow(item)
                    if item.id != visibleItems.last?.id {
                        Divider()
                            .padding(.leading, 36)
                    }
                }

                if remaining > 0 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            visibleInteractionCount += 10
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                            Text("\(min(remaining, 10)) more…")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                } else if visibleInteractionCount > 3 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            visibleInteractionCount = 3
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.up")
                                .font(.caption2)
                            Text("Show fewer")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
            }
        })
    }

    private func interactionRow(_ item: SamEvidenceItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Source icon
            Image(systemName: item.source.iconName)
                .font(.caption)
                .foregroundStyle(item.source.iconColor)
                .frame(width: 16, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline)
                    .lineLimit(2)

                if !item.snippet.isEmpty {
                    Text(item.snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Text(item.occurredAt.formatted(date: .abbreviated, time: .omitted))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Social Platforms

    /// Whether the person has any LinkedIn or Facebook data worth displaying.
    private var hasSocialPlatformData: Bool {
        person.linkedInProfileURL != nil ||
        person.linkedInConnectedOn != nil ||
        person.facebookFriendedOn != nil ||
        person.facebookMessageCount > 0
    }

    private var socialPlatformSection: some View {
        samSection(title: "Social Platforms") {
            VStack(alignment: .leading, spacing: 10) {
                // LinkedIn
                if person.linkedInProfileURL != nil || person.linkedInConnectedOn != nil {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "network")
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .frame(width: 16, alignment: .center)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("LinkedIn")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            if let connectedOn = person.linkedInConnectedOn {
                                Text("Connected \(connectedOn.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if let url = person.linkedInProfileURL {
                                let fullURL = url.hasPrefix("http") ? url : "https://\(url)"
                                Button {
                                    if let nsURL = URL(string: fullURL) {
                                        NSWorkspace.shared.open(nsURL)
                                    }
                                } label: {
                                    Text(url)
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Facebook
                if person.facebookFriendedOn != nil || person.facebookMessageCount > 0 {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "person.2.fill")
                            .font(.caption)
                            .foregroundStyle(.indigo)
                            .frame(width: 16, alignment: .center)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Facebook")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            if let friendedOn = person.facebookFriendedOn {
                                Text("Friends since \(friendedOn.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if person.facebookMessageCount > 0 {
                                HStack(spacing: 12) {
                                    Label("\(person.facebookMessageCount) messages", systemImage: "message.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    if let lastMsg = person.facebookLastMessageDate {
                                        Text("Last: \(lastMsg.formatted(date: .abbreviated, time: .omitted))")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }

                            if person.facebookTouchScore > 0 {
                                Text("Interaction score: \(person.facebookTouchScore)")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.indigo.opacity(0.12))
                                    .foregroundStyle(.indigo)
                                    .clipShape(Capsule())
                            }

                            if let url = person.facebookProfileURL {
                                let fullURL = url.hasPrefix("http") ? url : "https://\(url)"
                                Button {
                                    if let nsURL = URL(string: fullURL) {
                                        NSWorkspace.shared.open(nsURL)
                                    }
                                } label: {
                                    Text(url)
                                        .font(.caption)
                                        .foregroundStyle(.indigo)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - More Details (collapsed by default)

    private var moreDetailsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toggle button — full row is clickable
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showMoreDetails.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showMoreDetails ? 90 : 0))
                        .animation(.easeInOut(duration: 0.2), value: showMoreDetails)
                    Text("More Details")
                        .font(.subheadline)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            // Expanded content
            if showMoreDetails {
                VStack(spacing: 0) {
                    // Full contact info
                    if let contact = fullContact {
                        contactSections(contact)
                    }

                    // Referred by
                    if hasReferralRole {
                        referredBySection
                    }

                    // Alerts
                    if person.consentAlertsCount > 0 || person.reviewAlertsCount > 0 {
                        samSection(title: "Alerts") {
                            alertsContent
                        }
                    }

                    // Contexts/participations
                    if !person.participations.isEmpty {
                        samSection(title: "Contexts") {
                            participationsContent
                        }
                    }

                    // Coverages
                    if !person.coverages.isEmpty {
                        samSection(title: "Coverages") {
                            coveragesContent
                        }
                    }

                    // Channel + cadence preferences
                    if !person.isMe {
                        samSection(title: "Communication Preferences") {
                            VStack(alignment: .leading, spacing: 4) {
                                channelPreferenceView
                                cadencePreferenceView
                            }
                        }
                    }

                    // Relationship health details
                    samSection(title: "Relationship Health") {
                        RelationshipHealthView(
                            health: personHealth
                        )
                    }
                }
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
            HStack {
                Spacer()
                GuideButton(articleID: "people.adding-notes")
            }
            .padding(.bottom, 4)

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
            
            if person.lifecycleStatus != .active {
                lifecycleBanner
            }
        }
    }
    
    // MARK: - Lifecycle Banner

    @ViewBuilder
    private var lifecycleBanner: some View {
        let status = person.lifecycleStatus
        HStack {
            Image(systemName: status.icon)
            switch status {
            case .archived:
                Text("Archived — not receiving suggestions")
            case .dnc:
                Text("Do Not Contact — no outreach will be generated")
            case .deceased:
                Text("Deceased — record preserved")
            case .active:
                EmptyView()
            }
            Spacer()
            Button("Reactivate") {
                applyLifecycleChange(.active)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .font(.caption)
        .foregroundStyle({
            switch status {
            case .archived: return Color.orange
            case .dnc:      return Color.red
            case .deceased: return Color.gray
            case .active:   return Color.green
            }
        }() as Color)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill({
                    switch status {
                    case .archived: return Color.orange.opacity(0.1)
                    case .dnc:      return Color.red.opacity(0.1)
                    case .deceased: return Color.gray.opacity(0.1)
                    case .active:   return Color.green.opacity(0.1)
                    }
                }() as Color)
        )
    }

    // MARK: - Lifecycle Actions

    private func applyLifecycleChange(_ newStatus: ContactLifecycleStatus) {
        let previousStatus = person.lifecycleStatusRawValue
        let personName = person.displayNameCache ?? person.displayName

        // Capture undo snapshot
        let snapshot = LifecycleChangeSnapshot(
            personID: person.id,
            personName: personName,
            previousStatusRawValue: previousStatus,
            newStatusRawValue: newStatus.rawValue
        )
        if let entry = try? UndoRepository.shared.capture(
            operation: .statusChanged,
            entityType: .person,
            entityID: person.id,
            entityDisplayName: personName,
            snapshot: snapshot
        ) {
            UndoCoordinator.shared.showToast(for: entry)
        }

        // Apply
        try? PeopleRepository.shared.setLifecycleStatus(newStatus, for: person)

        // Notify
        NotificationCenter.default.post(name: .samPersonDidChange, object: nil)
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
            // Resolve photo links now that social profiles and URL addresses are available.
            // Check all sources: SamPerson fields, social profiles, and URL addresses.
            let liFromSocial = contact.socialProfiles.first(where: {
                $0.service.lowercased() == "linkedin" ||
                ($0.urlString ?? "").lowercased().contains("linkedin.com/in/")
            })
            let liFromURL = contact.urlAddresses.first(where: { $0.lowercased().contains("linkedin.com/in/") })
            let resolvedLI = liFromSocial.flatMap({ $0.urlString?.isEmpty == false ? $0.urlString : $0.username }) ?? liFromURL

            let fbFromSocial = contact.socialProfiles.first(where: {
                $0.service.lowercased() == "facebook" ||
                ($0.urlString ?? "").lowercased().contains("facebook.com/")
            })
            let fbFromURL = contact.urlAddresses.first(where: { $0.lowercased().contains("facebook.com/") })
            let resolvedFB = fbFromSocial.flatMap({ $0.urlString?.isEmpty == false ? $0.urlString : $0.username }) ?? fbFromURL

            photoLinks = photoCoordinator.profileLinks(
                for: person,
                contactLinkedInURL: resolvedLI,
                contactFacebookURL: resolvedFB
            )
        } else {
            logger.error("Failed to load contact for identifier: \(identifier, privacy: .private)")
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

    private func viewInGraph() {
        let coordinator = RelationshipGraphCoordinator.shared
        coordinator.selectedNodeID = person.id
        // Center on the person's node if graph is ready
        if let node = coordinator.nodes.first(where: { $0.id == person.id }) {
            coordinator.viewportCenter = node.position
        }
        NotificationCenter.default.post(name: .samNavigateToGraph, object: nil)
    }

    private func createInContacts() {
        Task {
            let displayName = person.displayNameCache ?? person.displayName
            let email = person.emailCache ?? person.email

            // Search for an existing Apple Contact before creating a new one
            let existingMatches = await contactsService.searchContacts(query: displayName, keys: .detail)
            let existingContact: ContactDTO? = existingMatches.first { match in
                let nameMatch = match.displayName.lowercased() == displayName.lowercased()
                let emailMatch: Bool = {
                    guard let email else { return false }
                    return match.emailAddresses.contains { $0.lowercased() == email.lowercased() }
                }()
                return nameMatch || emailMatch
            }

            let contactDTO: ContactDTO
            if let existing = existingContact {
                // Use existing Apple Contact — add to SAM group if needed
                contactDTO = existing
                await contactsService.addContactToSAMGroup(identifier: existing.identifier)
                logger.debug("Linked to existing Apple Contact for \(displayName, privacy: .private)")
            } else {
                // No match — create new Apple Contact (auto-adds to SAM group)
                guard let created = await contactsService.createContact(
                    fullName: displayName,
                    email: email,
                    note: nil
                ) else {
                    errorMessage = "Failed to create contact in Apple Contacts"
                    showingError = true
                    return
                }
                contactDTO = created
                logger.debug("Created new Apple Contact for \(displayName, privacy: .private)")
            }

            // Link existing SamPerson to the contact (avoids creating a duplicate)
            do {
                try PeopleRepository.shared.linkPerson(person, toContact: contactDTO)
                await loadFullContact()
            } catch {
                errorMessage = "Failed to link contact: \(error.localizedDescription)"
                showingError = true
            }
        }
    }
    
    private func copyToClipboard(_ text: String) {
        ClipboardSecurity.copy(text, clearAfter: 60)
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



// MARK: - Role Suggestion Badge

/// Pulsing badge shown in the role area when SAM has a pending role suggestion.
private struct RoleSuggestionBadge: View {
    let suggestion: RoleSuggestion
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    @State private var isPulsing = false

    var body: some View {
        let style = RoleBadgeStyle.forBadge(suggestion.suggestedRole)
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: 8))
            Text(suggestion.suggestedRole)
                .font(.caption)
            Text("?")
                .font(.caption.bold())

            Button {
                withAnimation { onConfirm() }
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Confirm \(suggestion.suggestedRole) role")

            Button {
                withAnimation { onDismiss() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Dismiss suggestion")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(style.color.opacity(isPulsing ? 0.2 : 0.1))
        .foregroundStyle(style.color)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(style.color.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
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

// MARK: - EvidenceSource UI helpers (SwiftUI)

private extension EvidenceSource {
    var iconColor: Color {
        switch self {
        case .calendar:  return .blue
        case .mail:      return .orange
        case .contacts:  return .gray
        case .note:      return .yellow
        case .manual:    return .gray
        case .iMessage:  return .green
        case .phoneCall: return .green
        case .faceTime:  return .teal
        case .linkedIn:  return .blue
        case .facebook:  return .indigo
        case .substack:  return .orange
        case .clipboardCapture: return .purple
        case .whatsApp:  return .green
        case .whatsAppCall: return .green
        }
    }
}
