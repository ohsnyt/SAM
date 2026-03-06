//
//  LinkedInImportReviewSheet.swift
//  SAM
//
//  Phase 3: LinkedIn Import Review UI
//  Phase 4: Enhanced De-duplication — adds "Probable Matches" section
//
//  Presents parsed LinkedIn connections in three sections:
//   - "Probable Matches" — contacts that likely match existing SAM contacts (default: Merge)
//   - "Recommended to Add" — contacts with touch score > 0 and no match (default ON)
//   - "No Recent Interaction" — contacts with no touch signals and no match (default OFF)
//

import SwiftUI

// MARK: - Sheet

struct LinkedInImportReviewSheet: View {

    let coordinator: LinkedInImportCoordinator
    let onDismiss: () -> Void

    /// Per-candidate classification state. Seeded from defaultClassification in onAppear.
    @State private var classifications: [UUID: LinkedInClassification] = [:]
    @State private var isImporting = false
    @State private var showSyncConfirmation = false
    /// Snapshot of sync candidates captured when the confirmation alert is shown.
    @State private var syncCandidatesSnapshot: [AppleContactsSyncCandidate] = []

    // MARK: - Partitioned candidates

    /// Candidates that probably match an existing SAM contact and need user confirmation.
    private var probableMatches: [LinkedInImportCandidate] {
        coordinator.importCandidates
            .filter { $0.matchStatus.isProbable }
            .sorted { ($0.touchScore?.totalScore ?? 0) > ($1.touchScore?.totalScore ?? 0) }
    }

    /// No-match candidates with touch score > 0 (recommended to add).
    private var recommendedToAdd: [LinkedInImportCandidate] {
        coordinator.importCandidates
            .filter { $0.matchStatus == .noMatch && ($0.touchScore?.totalScore ?? 0) > 0 }
            .sorted { ($0.touchScore?.totalScore ?? 0) > ($1.touchScore?.totalScore ?? 0) }
    }

    /// No-match candidates with no touch score (no recent interaction).
    private var noInteraction: [LinkedInImportCandidate] {
        coordinator.importCandidates
            .filter { $0.matchStatus == .noMatch && ($0.touchScore?.totalScore ?? 0) == 0 }
            .sorted { ($0.connectedOn ?? .distantPast) > ($1.connectedOn ?? .distantPast) }
    }

    // MARK: - Summary counts

    private var addCount: Int {
        coordinator.importCandidates.filter {
            let c = classifications[$0.id] ?? $0.defaultClassification
            return c == .add || c == .skip
        }.count
    }
    private var mergeCount: Int {
        coordinator.importCandidates.filter {
            (classifications[$0.id] ?? $0.defaultClassification) == .merge
        }.count
    }
    private var laterCount: Int {
        coordinator.importCandidates.filter {
            (classifications[$0.id] ?? $0.defaultClassification) == .later
        }.count
    }
    private var skipCount: Int {
        coordinator.importCandidates.filter {
            (classifications[$0.id] ?? $0.defaultClassification) == .skip
        }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Button("Cancel") {
                    coordinator.cancelImport()
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                VStack(spacing: 2) {
                    Text("LinkedIn Import Review")
                        .font(.headline)
                    subtitleText
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Import") {
                    Task {
                        isImporting = true
                        await coordinator.confirmImport(classifications: classifications)
                        isImporting = false
                        // §13 — if auto-sync is off, build sync candidates now and
                        // show confirmation if there are contacts to update.
                        if !coordinator.autoSyncLinkedInURLs {
                            await coordinator.prepareSyncCandidates(classifications: classifications)
                            if !coordinator.appleContactsSyncCandidates.isEmpty {
                                syncCandidatesSnapshot = coordinator.appleContactsSyncCandidates
                                showSyncConfirmation = true
                                // Don't dismiss yet — wait for the user's sync decision
                                return
                            }
                        }
                        onDismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isImporting)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()

            Divider()

            if isImporting {
                ProgressView()
                    .progressViewStyle(.linear)
                    .padding(.horizontal)
                    .padding(.top, 8)

                if let progress = coordinator.progressMessage {
                    Text(progress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }

                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {

                        // Probable Matches section — must be resolved before import
                        if !probableMatches.isEmpty {
                            Section {
                                ForEach(probableMatches) { candidate in
                                    ProbableMatchRow(
                                        candidate: candidate,
                                        isMerging: (classifications[candidate.id] ?? candidate.defaultClassification) == .merge,
                                        onMerge: { classifications[candidate.id] = .merge },
                                        onSkip:  { classifications[candidate.id] = .skip }
                                    )
                                    Divider().padding(.leading, 44)
                                }
                            } header: {
                                sectionHeader(
                                    title: "Probable Matches",
                                    count: probableMatches.count,
                                    actionLabel: "Merge All",
                                    action: { setAll(probableMatches, to: .merge) }
                                )
                            }
                        }

                        // Recommended to Add section
                        if !recommendedToAdd.isEmpty {
                            Section {
                                ForEach(recommendedToAdd) { candidate in
                                    CandidateRow(
                                        candidate: candidate,
                                        isAdding: (classifications[candidate.id] ?? candidate.defaultClassification) == .add,
                                        onToggle: { toggle(candidate) }
                                    )
                                    Divider().padding(.leading, 44)
                                }
                            } header: {
                                sectionHeader(
                                    title: "Recommended to Add",
                                    count: recommendedToAdd.count,
                                    actionLabel: "Add All",
                                    action: { setAll(recommendedToAdd, to: .add) }
                                )
                            }
                        }

                        // No Recent Interaction section
                        if !noInteraction.isEmpty {
                            Section {
                                ForEach(noInteraction) { candidate in
                                    CandidateRow(
                                        candidate: candidate,
                                        isAdding: (classifications[candidate.id] ?? candidate.defaultClassification) == .add,
                                        onToggle: { toggle(candidate) }
                                    )
                                    Divider().padding(.leading, 44)
                                }
                            } header: {
                                sectionHeader(
                                    title: "No Recent Interaction",
                                    count: noInteraction.count,
                                    actionLabel: "Add All",
                                    action: { setAll(noInteraction, to: .add) }
                                )
                            }
                        }

                        if coordinator.importCandidates.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "checkmark.circle")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                                Text("All connections already in SAM")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(40)
                        }
                    }
                }

                // Footer summary
                Divider()
                HStack {
                    footerText
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 660, minHeight: 500)
        .onAppear { seedClassifications() }
        .sheet(isPresented: $showSyncConfirmation) {
            AppleContactsSyncConfirmationSheet(
                candidates: syncCandidatesSnapshot,
                onSync: {
                    Task {
                        await coordinator.performAppleContactsSync(candidates: syncCandidatesSnapshot)
                        showSyncConfirmation = false
                        onDismiss()
                    }
                },
                onSkip: {
                    coordinator.dismissAppleContactsSync()
                    showSyncConfirmation = false
                    onDismiss()
                }
            )
        }
    }

    // MARK: - Dynamic text

    @ViewBuilder
    private var subtitleText: some View {
        let total = coordinator.pendingConnectionCount
        let exact = coordinator.exactMatchCount
        if exact > 0 {
            Text("\(total) connections · \(exact) already matched · \(addCount) to add · \(laterCount) to later")
        } else {
            Text("\(total) connections · \(addCount) to add · \(laterCount) to later")
        }
    }

    @ViewBuilder
    private var footerText: some View {
        if mergeCount > 0 {
            Text("\(addCount) to add · \(mergeCount) to merge · \(laterCount) to later")
        } else {
            Text("\(addCount) to add · \(laterCount) to later")
        }
    }

    // MARK: - Section Header

    private func sectionHeader(
        title: String,
        count: Int,
        actionLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
            Text("(\(count))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button(actionLabel, action: action)
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundStyle(.blue)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    // MARK: - Helpers

    private func seedClassifications() {
        for candidate in coordinator.importCandidates {
            if classifications[candidate.id] == nil {
                classifications[candidate.id] = candidate.defaultClassification
            }
        }
    }

    /// For Add/Later candidates: toggle between .add and .later.
    private func toggle(_ candidate: LinkedInImportCandidate) {
        let current = classifications[candidate.id] ?? candidate.defaultClassification
        classifications[candidate.id] = current == .add ? .later : .add
    }

    private func setAll(_ candidates: [LinkedInImportCandidate], to classification: LinkedInClassification) {
        for candidate in candidates {
            classifications[candidate.id] = classification
        }
    }
}

// MARK: - Probable Match Row

/// Shows a side-by-side comparison of the LinkedIn import data and the existing SAM contact.
/// The user chooses Merge (accept the match) or Keep Separate (reject the match, create new contact).
private struct ProbableMatchRow: View {
    let candidate: LinkedInImportCandidate
    let isMerging: Bool
    let onMerge: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Match reason label
            if let status = matchReason {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Capsule())
            }

            HStack(alignment: .top, spacing: 16) {
                // Left: LinkedIn data
                VStack(alignment: .leading, spacing: 3) {
                    Text("From LinkedIn")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(candidate.fullName.isEmpty ? "Unknown" : candidate.fullName)
                        .fontWeight(.medium)
                    if let pos = candidate.position, !pos.isEmpty {
                        Text(pos).font(.caption).foregroundStyle(.secondary)
                    }
                    if let co = candidate.company, !co.isEmpty {
                        Text(co).font(.caption).foregroundStyle(.secondary)
                    }
                    if let email = candidate.email, !email.isEmpty {
                        Text(email).font(.caption).foregroundStyle(.tertiary)
                    }
                    if let connectedOn = candidate.connectedOn {
                        Text("Connected \(connectedOn.formatted(.dateTime.month(.abbreviated).year()))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                // Right: existing SAM contact
                if let info = candidate.matchedPersonInfo {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Existing in SAM")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(info.displayName)
                            .fontWeight(.medium)
                        if let pos = info.position, !pos.isEmpty {
                            Text(pos).font(.caption).foregroundStyle(.secondary)
                        }
                        if let co = info.company, !co.isEmpty {
                            Text(co).font(.caption).foregroundStyle(.secondary)
                        }
                        if let email = info.email, !email.isEmpty {
                            Text(email).font(.caption).foregroundStyle(.tertiary)
                        }
                        if let url = info.linkedInURL, !url.isEmpty {
                            Text("Has LinkedIn URL")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Action buttons
            HStack(spacing: 10) {
                Button(action: onMerge) {
                    Label("Merge", systemImage: "arrow.triangle.merge")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(isMerging ? .blue : .secondary)
                .controlSize(.small)

                Button(action: onSkip) {
                    Label("Keep Separate", systemImage: "arrow.left.arrow.right")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(!isMerging ? .orange : .secondary)
                .controlSize(.small)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(isMerging ? Color.blue.opacity(0.04) : Color.orange.opacity(0.04))
        .contentShape(Rectangle())
    }

    private var matchReason: String? {
        switch candidate.matchStatus {
        case .probableMatchEmail:       return "Matched by email address"
        case .probableMatchNameCompany: return "Matched by name + company"
        default:                        return nil
        }
    }
}

// MARK: - Candidate Row

private struct CandidateRow: View {
    let candidate: LinkedInImportCandidate
    let isAdding: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                // Checkbox
                Image(systemName: isAdding ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isAdding ? .blue : .secondary)
                    .font(.system(size: 18))
                    .frame(width: 24)

                // Contact info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(candidate.fullName.isEmpty ? "Unknown" : candidate.fullName)
                            .fontWeight(.medium)

                        if let score = candidate.touchScore, score.totalScore > 0 {
                            Text("Score: \(score.totalScore)")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.15))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }
                    }

                    // Company / position
                    if let company = candidate.company, !company.isEmpty {
                        HStack(spacing: 4) {
                            if let position = candidate.position, !position.isEmpty {
                                Text("\(position) · \(company)")
                            } else {
                                Text(company)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    // Touch summary + connection date
                    HStack(spacing: 8) {
                        if let score = candidate.touchScore, !score.touchSummary.isEmpty {
                            Text(score.touchSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let connectedOn = candidate.connectedOn {
                            Text("Connected \(connectedOn.formatted(.dateTime.month(.abbreviated).year()))")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Apple Contacts Sync Confirmation Sheet

/// One-shot confirmation sheet shown after import when SAM found contacts
/// whose Apple Contact record doesn't yet have their LinkedIn URL.
/// (§13.1 — batch LinkedIn URL enrichment of Apple Contacts)
private struct AppleContactsSyncConfirmationSheet: View {
    let candidates: [AppleContactsSyncCandidate]
    let onSync: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            // Icon + title
            VStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue)

                Text("Add LinkedIn URLs to Apple Contacts?")
                    .font(.headline)

                Text("SAM found LinkedIn profile URLs for \(candidates.count) contact\(candidates.count == 1 ? "" : "s") marked Add. Adding them to Apple Contacts makes it easy to find their LinkedIn profile from your phone's Contacts app.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Contact list (scrollable, max height ~180)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(candidates) { candidate in
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                                .font(.caption)
                            Text(candidate.displayName)
                                .font(.caption)
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(maxHeight: 180)
            .padding(.horizontal)

            // Action buttons
            HStack(spacing: 12) {
                Button("Not Now") {
                    onSkip()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button("Add LinkedIn URLs to Apple Contacts") {
                    onSync()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

// MARK: - Preview

#Preview {
    LinkedInImportReviewSheet(
        coordinator: LinkedInImportCoordinator.shared,
        onDismiss: {}
    )
}
