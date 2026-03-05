//
//  UnknownSenderTriageSection.swift
//  SAM
//
//  Compact triage list for unknown email/calendar senders in the Awareness view.
//  Radio buttons: Add | Not Now (default) | Never — staged until user clicks Done.
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "UnknownSenderTriage")

/// Per-sender triage choice. Default is .notNow.
private enum TriageChoice: String, CaseIterable {
    case add       // promote to contact, reprocess emails
    case notNow    // dismiss for now, resurfaces on next email
    case never     // permanently block
}

/// Holds a pending match between an unknown sender and an existing Apple Contact
/// that is NOT yet in the SAM group, so the user can confirm or reject the link.
private struct TriageMatchCandidate: Identifiable {
    let id = UUID()
    let sender: UnknownSender
    let matchedContact: ContactDTO
    var resolution: Resolution = .pending

    enum Resolution {
        case pending
        case samePerson   // link to existing contact + add to SAM group
        case differentPerson  // create a new contact
    }

    var isResolved: Bool { resolution != .pending }
}

struct UnknownSenderTriageSection: View {

    @State private var pendingSenders: [UnknownSender] = []
    @State private var choices: [UUID: TriageChoice] = [:]  // staged choices
    @State private var isSaving = false
    @State private var isExpanded = false
    @State private var pendingMatches: [TriageMatchCandidate] = []
    @State private var showMatchConfirmation = false

    /// Number of rows to show when collapsed.
    private let collapsedRowCount = 3

    private let repository = UnknownSenderRepository.shared
    private let contactsService = ContactsService.shared
    private let peopleRepository = PeopleRepository.shared
    private var mailCoordinator: MailImportCoordinator { MailImportCoordinator.shared }
    private var calendarCoordinator: CalendarImportCoordinator { CalendarImportCoordinator.shared }
    private var linkedInCoordinator: LinkedInImportCoordinator { LinkedInImportCoordinator.shared }
    private var facebookCoordinator: FacebookImportCoordinator { FacebookImportCoordinator.shared }

    var body: some View {
        // VStack is always present so lifecycle modifiers always fire.
        // Content inside is conditional — avoids Group + @ViewBuilder re-render bug.
        VStack(spacing: 0) {
            if !pendingSenders.isEmpty {
                triageCard
            }
        }
        .task {
            loadPendingSenders()
        }
        .onChange(of: mailCoordinator.importStatus) { _, newStatus in
            if newStatus == .success {
                loadPendingSenders()
            }
        }
        .onChange(of: calendarCoordinator.importStatus) { _, newStatus in
            if newStatus == .success {
                loadPendingSenders()
            }
        }
        .onChange(of: linkedInCoordinator.importStatus) { _, newStatus in
            if newStatus == .success {
                loadPendingSenders()
            }
        }
        .onChange(of: facebookCoordinator.importStatus) { _, newStatus in
            if newStatus == .success {
                loadPendingSenders()
            }
        }
        .sheet(isPresented: $showMatchConfirmation) {
            TriageMatchConfirmationView(
                pendingMatches: $pendingMatches,
                onDone: { resolvedMatches in
                    commitResolvedMatches(resolvedMatches)
                }
            )
        }
    }

    private var triageCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Label("Unknown Senders", systemImage: "person.fill.questionmark")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text("\(pendingSenders.count)")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange)
                    .clipShape(Capsule())

                Spacer()

                if hasChanges {
                    Text("\(changesSummary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Expand / collapse toggle
                if allSenders.count > collapsedRowCount {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isExpanded {
                                Text("Show less")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Show all \(allSenders.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Column header
            HStack(spacing: 0) {
                Text("Add")
                    .frame(width: 36, alignment: .center)
                Text("Later")
                    .frame(width: 36, alignment: .center)
                Text("Never")
                    .frame(width: 36, alignment: .center)

                Text("Sender")
                    .padding(.leading, 8)

                Spacer()

                Text("Subject / Profile")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal)
            .padding(.bottom, 4)

            Divider()
                .padding(.horizontal)

            // Sender list — clipped to first N rows when collapsed
            VStack(spacing: 0) {
                let visibleLinkedIn = isExpanded ? linkedInSenders : Array(linkedInSenders.prefix(collapsedRowCount))
                let linkedInShown = min(linkedInSenders.count, isExpanded ? linkedInSenders.count : collapsedRowCount)
                let remainingAfterLinkedIn = collapsedRowCount - linkedInShown
                let visibleFacebook = isExpanded ? facebookSenders : Array(facebookSenders.prefix(max(0, remainingAfterLinkedIn)))
                let facebookShown = min(facebookSenders.count, isExpanded ? facebookSenders.count : max(0, remainingAfterLinkedIn))
                let remainingAfterFacebook = collapsedRowCount - linkedInShown - facebookShown
                let visibleRegular = isExpanded ? regularSenders : Array(regularSenders.prefix(max(0, remainingAfterFacebook)))
                let regularShown = min(regularSenders.count, isExpanded ? regularSenders.count : max(0, remainingAfterFacebook))
                let remainingAfterRegular = collapsedRowCount - linkedInShown - facebookShown - regularShown
                let visibleMarketing = isExpanded ? marketingSenders : Array(marketingSenders.prefix(max(0, remainingAfterRegular)))

                // LinkedIn contacts (sorted by touch score)
                if !visibleLinkedIn.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "network")
                            .font(.caption)
                            .foregroundStyle(.blue)
                        Text("LinkedIn Connections")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Scored by interaction history")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal)
                    .padding(.top, 4)
                    .padding(.bottom, 4)

                    ForEach(visibleLinkedIn, id: \.id) { sender in
                        LinkedInTriageRow(sender: sender, choice: binding(for: sender.id))
                    }

                    if !visibleFacebook.isEmpty || !visibleRegular.isEmpty || !visibleMarketing.isEmpty {
                        Divider().padding(.horizontal)
                    }
                }

                // Facebook friends (sorted by touch score)
                if !visibleFacebook.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2.fill")
                            .font(.caption)
                            .foregroundStyle(.indigo)
                        Text("Facebook Friends")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Scored by interaction history")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal)
                    .padding(.top, 4)
                    .padding(.bottom, 4)

                    ForEach(visibleFacebook, id: \.id) { sender in
                        FacebookTriageRow(sender: sender, choice: binding(for: sender.id))
                    }

                    if !visibleRegular.isEmpty || !visibleMarketing.isEmpty {
                        Divider().padding(.horizontal)
                    }
                }

                // Personal / business senders (default: Later)
                ForEach(visibleRegular, id: \.id) { sender in
                    TriageRow(sender: sender, choice: binding(for: sender.id))
                }

                // Mailing list / marketing senders (default: Never)
                if !visibleMarketing.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "envelope.badge.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text("Mailing Lists & Marketing")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Defaulting to Never")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal)
                    .padding(.top, visibleRegular.isEmpty ? 0 : 8)
                    .padding(.bottom, 4)

                    if !visibleRegular.isEmpty {
                        Divider().padding(.horizontal)
                    }

                    ForEach(visibleMarketing, id: \.id) { sender in
                        TriageRow(sender: sender, choice: binding(for: sender.id))
                    }
                }

                // "X more" hint when collapsed and there are hidden rows
                if !isExpanded && allSenders.count > collapsedRowCount {
                    let hiddenCount = allSenders.count - collapsedRowCount
                    Text("\(hiddenCount) more \u{2014} tap Show all to expand")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6)
                }
            }

            Divider()
                .padding(.horizontal)

            // Footer — always visible regardless of expand state
            HStack {
                Spacer()

                if isSaving {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Saving...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Done") {
                    saveChoices()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isSaving)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .padding()
    }

    // MARK: - Helpers

    private func binding(for id: UUID) -> Binding<TriageChoice> {
        Binding(
            get: { choices[id] ?? .notNow },
            set: { choices[id] = $0 }
        )
    }

    private var hasChanges: Bool {
        choices.values.contains(where: { $0 != .notNow })
    }

    private var changesSummary: String {
        let addCount = choices.values.filter { $0 == .add }.count
        let neverCount = choices.values.filter { $0 == .never }.count
        var parts: [String] = []
        if addCount > 0 { parts.append("\(addCount) to add") }
        if neverCount > 0 { parts.append("\(neverCount) to block") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Sender Groups

    /// All pending senders in display order: LinkedIn, Facebook, regular, marketing.
    private var allSenders: [UnknownSender] {
        linkedInSenders + facebookSenders + regularSenders + marketingSenders
    }

    /// LinkedIn senders (source == .linkedIn), sorted by touch score descending.
    private var linkedInSenders: [UnknownSender] {
        pendingSenders
            .filter { $0.source == .linkedIn && !$0.isLikelyMarketing }
            .sorted { $0.intentionalTouchScore > $1.intentionalTouchScore }
    }

    /// Facebook senders (source == .facebook), sorted by touch score descending.
    private var facebookSenders: [UnknownSender] {
        pendingSenders
            .filter { $0.source == .facebook && !$0.isLikelyMarketing }
            .sorted { $0.intentionalTouchScore > $1.intentionalTouchScore }
    }

    /// Regular (personal/business) senders from non-LinkedIn, non-Facebook sources — default choice: Later.
    private var regularSenders: [UnknownSender] {
        pendingSenders.filter { $0.source != .linkedIn && $0.source != .facebook && !$0.isLikelyMarketing }
    }

    /// Likely mailing list or marketing senders — default choice: Never.
    private var marketingSenders: [UnknownSender] {
        pendingSenders.filter { $0.isLikelyMarketing }
    }

    // MARK: - Data Loading

    func loadPendingSenders() {
        do {
            let fetched = try repository.fetchPending()
            logger.info("loadPendingSenders: fetched \(fetched.count) pending senders")
            pendingSenders = fetched
            // Set default choice for any new senders:
            // marketing senders default to Never; personal senders default to Later.
            for sender in pendingSenders where choices[sender.id] == nil {
                choices[sender.id] = sender.isLikelyMarketing ? .never : .notNow
            }
            // Clean up choices for senders no longer pending
            let validIDs = Set(pendingSenders.map(\.id))
            choices = choices.filter { validIDs.contains($0.key) }
        } catch {
            logger.error("loadPendingSenders failed: \(error)")
        }
    }

    // MARK: - Save

    private func saveChoices() {
        isSaving = true

        // Snapshot the current choices before async work
        let currentChoices = choices
        let sendersByID = Dictionary(uniqueKeysWithValues: pendingSenders.map { ($0.id, $0) })

        // Collect senders by action
        var toAdd: [UnknownSender] = []
        var toNever: [UnknownSender] = []
        var notNowCount = 0
        var processedIDs: Set<UUID> = []

        for (id, choice) in currentChoices {
            guard let sender = sendersByID[id] else { continue }
            switch choice {
            case .add:
                toAdd.append(sender)
                processedIDs.insert(id)
            case .never:
                toNever.append(sender)
                processedIDs.insert(id)
            case .notNow:
                notNowCount += 1  // leave as .pending — no DB change
            }
        }

        // Process never-include synchronously (fast)
        do {
            for sender in toNever {
                try repository.markNeverInclude(sender)
            }
        } catch {
            logger.error("Failed to mark never-include: \(error)")
        }

        // Mark add senders immediately (optimistic) so they leave the list
        // even if background contact creation fails
        for sender in toAdd {
            do {
                try repository.markAdded(sender)
            } catch {
                logger.error("Failed to mark added for \(sender.email, privacy: .public): \(error)")
            }
        }

        // Remove processed senders from UI immediately
        pendingSenders.removeAll { processedIDs.contains($0.id) }
        choices = choices.filter { !processedIDs.contains($0.key) }

        if toAdd.isEmpty {
            isSaving = false
            logger.info("Triage complete: \(toNever.count) blocked, \(notNowCount) deferred")
            return
        }

        // Create contacts + reprocess in background
        Task {
            var addedEmails: [String] = []
            var matchesNeedingConfirmation: [TriageMatchCandidate] = []

            for sender in toAdd {
                let isLinkedIn = sender.email.hasPrefix("linkedin:") || sender.email.hasPrefix("linkedin-unknown-")
                let isFacebook = sender.source == .facebook || sender.email.hasPrefix("facebook:")
                let isSocialPlatform = isLinkedIn || isFacebook

                let displayName = sender.displayName ?? (isLinkedIn ? "LinkedIn Contact" : (isFacebook ? "Facebook Friend" : sender.email))

                if isSocialPlatform {
                    // Social platform senders → create standalone SamPerson (no Apple Contact)
                    let linkedInURL: String? = isLinkedIn ? sender.latestSubject : nil
                    do {
                        try peopleRepository.upsertFromSocialImport(
                            displayName: displayName,
                            linkedInProfileURL: linkedInURL,
                            facebookFriendedOn: sender.facebookFriendedOn,
                            facebookMessageCount: sender.facebookMessageCount,
                            facebookLastMessageDate: sender.facebookLastMessageDate,
                            facebookTouchScore: sender.intentionalTouchScore
                        )
                    } catch {
                        logger.error("Failed to create SamPerson for \(sender.email, privacy: .public): \(error)")
                    }
                } else {
                    // Email/calendar senders → search ALL Apple Contacts for a match
                    let existingMatches = await contactsService.searchContacts(
                        query: displayName,
                        keys: .detail
                    )
                    let existingContact: ContactDTO? = existingMatches.first { match in
                        let nameMatch = match.displayName.lowercased() == displayName.lowercased()
                        let emailMatch = match.emailAddresses.contains { $0.lowercased() == sender.email.lowercased() }
                        return nameMatch || emailMatch
                    }

                    if let existing = existingContact {
                        // Check if already in SAM group → auto-link directly
                        let inSAMGroup = await contactsService.isContactInSAMGroup(identifier: existing.identifier)
                        if inSAMGroup {
                            logger.info("Triage: auto-linking '\(displayName, privacy: .public)' (already in SAM group)")
                            do {
                                try peopleRepository.upsert(contact: existing)
                                addedEmails.append(sender.email)
                            } catch {
                                logger.error("Failed to upsert contact for \(sender.email, privacy: .public): \(error)")
                            }
                        } else {
                            // Match found but NOT in SAM group → needs user confirmation
                            logger.info("Triage: match found for '\(displayName, privacy: .public)' outside SAM group — queuing for confirmation")
                            matchesNeedingConfirmation.append(
                                TriageMatchCandidate(sender: sender, matchedContact: existing)
                            )
                        }
                    } else {
                        // No match → create new contact (existing behavior)
                        guard let created = await contactsService.createContact(
                            fullName: displayName,
                            email: sender.email,
                            note: nil
                        ) else {
                            logger.error("Failed to create contact for \(sender.email, privacy: .public)")
                            continue
                        }

                        do {
                            try peopleRepository.upsert(contact: created)
                            addedEmails.append(sender.email)
                        } catch {
                            logger.error("Failed to upsert contact for \(sender.email, privacy: .public): \(error)")
                        }
                    }
                }
            }

            // Refresh participant hints on existing evidence now that new contacts exist
            if !addedEmails.isEmpty {
                do {
                    try EvidenceRepository.shared.refreshParticipantResolution()
                } catch {
                    logger.error("Failed to refresh participant resolution after triage: \(error)")
                }
            }

            // Reprocess added senders' interaction history in background
            for email in addedEmails {
                await mailCoordinator.reprocessForSender(email: email)
            }
            for sender in toAdd where sender.source == .linkedIn {
                if let profileURL = sender.latestSubject, !profileURL.isEmpty {
                    await linkedInCoordinator.reprocessForSender(profileURL: profileURL)
                }
            }

            // If there are matches needing confirmation, show the sheet; otherwise we're done
            if !matchesNeedingConfirmation.isEmpty {
                pendingMatches = matchesNeedingConfirmation
                showMatchConfirmation = true
            }

            isSaving = false

            logger.info("Triage complete: \(toAdd.count) processed, \(toNever.count) blocked, \(notNowCount) deferred, \(matchesNeedingConfirmation.count) pending confirmation")
        }
    }

    /// Process resolved matches after the user confirms/rejects each one in the sheet.
    private func commitResolvedMatches(_ resolved: [TriageMatchCandidate]) {
        Task {
            var addedEmails: [String] = []

            for match in resolved {
                let sender = match.sender
                let displayName = sender.displayName ?? sender.email

                switch match.resolution {
                case .samePerson:
                    // Link to existing contact + add to SAM group
                    logger.info("Triage confirm: linking '\(displayName, privacy: .public)' to existing contact \(match.matchedContact.identifier, privacy: .public)")
                    do {
                        try peopleRepository.upsert(contact: match.matchedContact)
                        addedEmails.append(sender.email)
                    } catch {
                        logger.error("Failed to upsert matched contact for \(sender.email, privacy: .public): \(error)")
                    }
                    await contactsService.addContactToSAMGroup(identifier: match.matchedContact.identifier)

                case .differentPerson:
                    // Create a brand-new Apple Contact + add to SAM group
                    logger.info("Triage confirm: creating new contact for '\(displayName, privacy: .public)' (rejected match)")
                    guard let created = await contactsService.createContact(
                        fullName: displayName,
                        email: sender.email,
                        note: nil
                    ) else {
                        logger.error("Failed to create contact for \(sender.email, privacy: .public)")
                        continue
                    }
                    do {
                        try peopleRepository.upsert(contact: created)
                        addedEmails.append(sender.email)
                    } catch {
                        logger.error("Failed to upsert new contact for \(sender.email, privacy: .public): \(error)")
                    }

                case .pending:
                    // Should not happen — log and skip
                    logger.warning("Triage confirm: unresolved match for '\(displayName, privacy: .public)' — skipping")
                }
            }

            if !addedEmails.isEmpty {
                do {
                    try EvidenceRepository.shared.refreshParticipantResolution()
                } catch {
                    logger.error("Failed to refresh participant resolution after match confirmation: \(error)")
                }
                for email in addedEmails {
                    await mailCoordinator.reprocessForSender(email: email)
                }
            }

            logger.info("Match confirmation complete: \(addedEmails.count) contacts processed")
        }
    }
}

// MARK: - LinkedIn Triage Row

/// A triage row for LinkedIn-sourced unknown senders.
/// Displays company/position and touch score.
private struct LinkedInTriageRow: View {
    let sender: UnknownSender
    @Binding var choice: TriageChoice

    var body: some View {
        HStack(spacing: 0) {
            // Add / Later / Never radio buttons
            radioButton(.add, color: .blue)
                .frame(width: 36)
            radioButton(.notNow, color: .secondary)
                .frame(width: 36)
            radioButton(.never, color: .red)
                .frame(width: 36)

            // Contact info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "network")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    Text(sender.displayName ?? sender.email)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if sender.intentionalTouchScore > 0 {
                        Text("Score: \(sender.intentionalTouchScore)")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                }

                if let position = sender.linkedInPosition, let company = sender.linkedInCompany {
                    Text("\(position) · \(company)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let company = sender.linkedInCompany {
                    Text(company)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let connectedOn = sender.linkedInConnectedOn {
                    Text("Connected \(connectedOn.formatted(.dateTime.month(.abbreviated).year()))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 180, alignment: .leading)
            .padding(.leading, 8)

            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal)
        .background(choice == .add ? Color.accentColor.opacity(0.05) :
                     choice == .never ? Color.red.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
    }

    private func radioButton(_ value: TriageChoice, color: Color) -> some View {
        Button {
            choice = value
        } label: {
            Image(systemName: choice == value ? "circle.inset.filled" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(choice == value ? color : .secondary.opacity(0.4))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Facebook Triage Row

/// A triage row for Facebook-sourced unknown senders.
/// Displays message count, friended date, and touch score.
private struct FacebookTriageRow: View {
    let sender: UnknownSender
    @Binding var choice: TriageChoice

    var body: some View {
        HStack(spacing: 0) {
            // Add / Later / Never radio buttons
            radioButton(.add, color: .blue)
                .frame(width: 36)
            radioButton(.notNow, color: .secondary)
                .frame(width: 36)
            radioButton(.never, color: .red)
                .frame(width: 36)

            // Contact info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill")
                        .font(.caption2)
                        .foregroundStyle(.indigo)
                    Text(sender.displayName ?? "Facebook Friend")
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if sender.intentionalTouchScore > 0 {
                        Text("Score: \(sender.intentionalTouchScore)")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.indigo.opacity(0.15))
                            .foregroundStyle(.indigo)
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 8) {
                    if sender.facebookMessageCount > 0 {
                        Text("\(sender.facebookMessageCount) messages")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let lastMsg = sender.facebookLastMessageDate {
                        Text("Last: \(lastMsg.formatted(.dateTime.month(.abbreviated).year()))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let friendedOn = sender.facebookFriendedOn {
                    Text("Friends since \(friendedOn.formatted(.dateTime.month(.abbreviated).year()))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 180, alignment: .leading)
            .padding(.leading, 8)

            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal)
        .background(choice == .add ? Color.accentColor.opacity(0.05) :
                     choice == .never ? Color.red.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
    }

    private func radioButton(_ value: TriageChoice, color: Color) -> some View {
        Button {
            choice = value
        } label: {
            Image(systemName: choice == value ? "circle.inset.filled" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(choice == value ? color : .secondary.opacity(0.4))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Triage Row

private struct TriageRow: View {
    let sender: UnknownSender
    @Binding var choice: TriageChoice

    var body: some View {
        HStack(spacing: 0) {
            // Radio buttons
            radioButton(.add, color: .blue)
                .frame(width: 36)
            radioButton(.notNow, color: .secondary)
                .frame(width: 36)
            radioButton(.never, color: .red)
                .frame(width: 36)

            // Sender name + source icon
            HStack(spacing: 4) {
                Image(systemName: sourceIcon(for: sender.source))
                    .font(.caption2)
                    .foregroundStyle(sourceColor(for: sender.source))
                Text(sender.displayName ?? sender.email)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(minWidth: 180, alignment: .leading)
            .padding(.leading, 8)

            // Subject — hide synthetic keys for social/messaging platform entries
            if sender.source != .facebook, let subject = sender.latestSubject,
               !subject.hasPrefix("linkedin:"), !subject.hasPrefix("facebook:"),
               !subject.hasPrefix("WhatsApp") {
                Text(subject)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
            } else {
                Spacer()
            }

            // Email count badge
            if sender.emailCount > 1 {
                Text("\(sender.emailCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
                    .padding(.trailing, 4)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal)
        .background(choice == .add ? Color.accentColor.opacity(0.05) :
                     choice == .never ? Color.red.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
    }

    private func radioButton(_ value: TriageChoice, color: Color) -> some View {
        Button {
            choice = value
        } label: {
            Image(systemName: choice == value ? "circle.inset.filled" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(choice == value ? color : .secondary.opacity(0.4))
        }
        .buttonStyle(.plain)
    }

    private func sourceIcon(for source: EvidenceSource) -> String {
        switch source {
        case .mail:             return "envelope"
        case .calendar:         return "calendar"
        case .linkedIn:         return "network"
        case .facebook:         return "person.2.fill"
        case .substack:         return "newspaper.fill"
        case .whatsApp:         return "text.bubble"
        case .whatsAppCall:     return "phone.bubble"
        case .iMessage:         return "message"
        case .phoneCall:        return "phone"
        case .faceTime:         return "video"
        default:                return "person.crop.circle"
        }
    }

    private func sourceColor(for source: EvidenceSource) -> Color {
        switch source {
        case .mail:             return .blue
        case .calendar:         return .red
        case .linkedIn:         return .blue
        case .facebook:         return .indigo
        case .substack:         return .orange
        case .whatsApp:         return .green
        case .whatsAppCall:     return .green
        case .iMessage:         return .teal
        case .phoneCall:        return .green
        case .faceTime:         return .mint
        default:                return .secondary
        }
    }
}

// MARK: - Match Confirmation Sheet

/// Sheet presented when triage "Add" matches existing Apple Contacts outside the SAM group.
/// User confirms each: "Same Person" (link + add to SAM group) or "Different Person" (create new).
private struct TriageMatchConfirmationView: View {
    @Binding var pendingMatches: [TriageMatchCandidate]
    let onDone: ([TriageMatchCandidate]) -> Void

    @Environment(\.dismiss) private var dismiss

    private var allResolved: Bool {
        pendingMatches.allSatisfy(\.isResolved)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Label("SAM found existing contacts that may match", systemImage: "person.2.badge.gearshape")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            // Match list
            ScrollView {
                VStack(spacing: 0) {
                    ForEach($pendingMatches) { $match in
                        MatchRow(match: $match)
                        Divider().padding(.horizontal)
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                Text("\(pendingMatches.filter(\.isResolved).count) of \(pendingMatches.count) resolved")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Done") {
                    let resolved = pendingMatches
                    dismiss()
                    onDone(resolved)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!allResolved)
            }
            .padding()
        }
        .frame(minWidth: 520, idealWidth: 580, minHeight: 300, idealHeight: 420)
    }
}

/// A single match row inside the confirmation sheet.
private struct MatchRow: View {
    @Binding var match: TriageMatchCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Unknown sender info
            HStack(spacing: 6) {
                Image(systemName: "person.fill.questionmark")
                    .foregroundStyle(.orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unknown sender")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(match.sender.displayName ?? match.sender.email)
                        .font(.body)
                        .fontWeight(.medium)
                    Text(match.sender.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Matched contact info
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Existing Apple Contact")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(match.matchedContact.displayName)
                        .font(.body)
                        .fontWeight(.medium)
                    if !match.matchedContact.emailAddresses.isEmpty {
                        Text(match.matchedContact.emailAddresses.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !match.matchedContact.phoneNumbers.isEmpty {
                        Text(match.matchedContact.phoneNumbers.map(\.number).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Action buttons
            HStack(spacing: 12) {
                Button {
                    match.resolution = .samePerson
                } label: {
                    Label("Same Person — Link", systemImage: "link")
                        .font(.callout)
                }
                .buttonStyle(.borderedProminent)
                .tint(match.resolution == .samePerson ? .blue : .gray.opacity(0.4))
                .controlSize(.small)

                Button {
                    match.resolution = .differentPerson
                } label: {
                    Label("Different — Create New", systemImage: "person.badge.plus")
                        .font(.callout)
                }
                .buttonStyle(.borderedProminent)
                .tint(match.resolution == .differentPerson ? .orange : .gray.opacity(0.4))
                .controlSize(.small)
            }
        }
        .padding()
        .background(match.isResolved ? Color.accentColor.opacity(0.03) : Color.clear)
    }
}
