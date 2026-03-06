//
//  FacebookImportReviewSheet.swift
//  SAM
//
//  Phase FB-1: Facebook Import Review UI
//
//  Presents parsed Facebook friends in three sections:
//   - "Probable Matches" — contacts that likely match existing SAM contacts (default: Merge)
//   - "Recommended to Add" — contacts with touch score > 0 and no match (default ON)
//   - "No Recent Interaction" — contacts with no touch signals and no match (default OFF)
//

import SwiftUI

// MARK: - Sheet (backward-compat wrapper)

struct FacebookImportReviewSheet: View {

    let coordinator: FacebookImportCoordinator
    let onDismiss: () -> Void

    @State private var classifications: [UUID: FacebookClassification] = [:]
    @State private var isImporting = false

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

                Text("Facebook Import Review")
                    .font(.headline)

                Spacer()

                Button("Import") {
                    Task {
                        isImporting = true
                        await coordinator.confirmImport(classifications: classifications)
                        isImporting = false
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
                VStack(spacing: 12) {
                    ProgressView()
                    if let progress = coordinator.progressMessage {
                        Text(progress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FacebookReviewContent(
                    coordinator: coordinator,
                    classifications: $classifications
                )
            }
        }
        .frame(minWidth: 660, minHeight: 500)
        .onAppear { seedClassifications() }
    }

    private func seedClassifications() {
        for candidate in coordinator.importCandidates {
            if classifications[candidate.id] == nil {
                classifications[candidate.id] = candidate.defaultClassification
            }
        }
    }
}

// MARK: - Reusable Review Content (embedded in both review sheet and import sheet)

struct FacebookReviewContent: View {

    let coordinator: FacebookImportCoordinator
    @Binding var classifications: [UUID: FacebookClassification]

    // MARK: - Partitioned candidates

    var probableMatches: [FacebookImportCandidate] {
        coordinator.importCandidates
            .filter { $0.matchStatus.isProbable }
            .sorted { ($0.touchScore?.totalScore ?? 0) > ($1.touchScore?.totalScore ?? 0) }
    }

    var recommendedToAdd: [FacebookImportCandidate] {
        coordinator.importCandidates
            .filter { $0.matchStatus == .noMatch && ($0.touchScore?.totalScore ?? 0) > 0 }
            .sorted { ($0.touchScore?.totalScore ?? 0) > ($1.touchScore?.totalScore ?? 0) }
    }

    var noInteraction: [FacebookImportCandidate] {
        coordinator.importCandidates
            .filter { $0.matchStatus == .noMatch && ($0.touchScore?.totalScore ?? 0) == 0 }
            .sorted { ($0.friendedOn ?? .distantPast) > ($1.friendedOn ?? .distantPast) }
    }

    // MARK: - Summary counts

    var addCount: Int {
        coordinator.importCandidates.filter {
            let c = classifications[$0.id] ?? $0.defaultClassification
            return c == .add || c == .skip
        }.count
    }

    var mergeCount: Int {
        coordinator.importCandidates.filter {
            (classifications[$0.id] ?? $0.defaultClassification) == .merge
        }.count
    }

    var laterCount: Int {
        coordinator.importCandidates.filter {
            (classifications[$0.id] ?? $0.defaultClassification) == .later
        }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {

                    // Probable Matches section
                    if !probableMatches.isEmpty {
                        Section {
                            ForEach(probableMatches) { candidate in
                                FacebookProbableMatchRow(
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
                                FacebookCandidateRow(
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
                                FacebookCandidateRow(
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
                            Text("All friends already in SAM")
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

    // MARK: - Dynamic text

    @ViewBuilder
    var footerText: some View {
        if mergeCount > 0 {
            Text("\(addCount) to add · \(mergeCount) to merge · \(laterCount) to later")
        } else {
            Text("\(addCount) to add · \(laterCount) to later")
        }
    }

    // MARK: - Section Header

    func sectionHeader(
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

    func seedClassifications() {
        for candidate in coordinator.importCandidates {
            if classifications[candidate.id] == nil {
                classifications[candidate.id] = candidate.defaultClassification
            }
        }
    }

    private func toggle(_ candidate: FacebookImportCandidate) {
        let current = classifications[candidate.id] ?? candidate.defaultClassification
        classifications[candidate.id] = current == .add ? .later : .add
    }

    private func setAll(_ candidates: [FacebookImportCandidate], to classification: FacebookClassification) {
        for candidate in candidates {
            classifications[candidate.id] = classification
        }
    }
}

// MARK: - Probable Match Row

/// Shows a side-by-side comparison of the Facebook import data and the existing SAM contact.
struct FacebookProbableMatchRow: View {
    let candidate: FacebookImportCandidate
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
                // Left: Facebook data
                VStack(alignment: .leading, spacing: 3) {
                    Text("From Facebook")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(candidate.displayName)
                        .fontWeight(.medium)
                    if candidate.messageCount > 0 {
                        Text("\(candidate.messageCount) messages")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let friendedOn = candidate.friendedOn {
                        Text("Friends since \(friendedOn.formatted(.dateTime.month(.abbreviated).year()))")
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
        case .exactMatchFacebookURL:       return "Matched by Facebook URL"
        case .probableMatchAppleContact:    return "Matched via Apple Contacts"
        case .probableMatchCrossPlatform:   return "Matched by name + LinkedIn"
        case .probableMatchName:            return "Matched by name"
        case .noMatch:                      return nil
        }
    }
}

// MARK: - Candidate Row

struct FacebookCandidateRow: View {
    let candidate: FacebookImportCandidate
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
                        Text(candidate.displayName)
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

                    // Message count
                    if candidate.messageCount > 0 {
                        Text("\(candidate.messageCount) messages")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Touch summary + friendship date
                    HStack(spacing: 8) {
                        if let score = candidate.touchScore, !score.touchSummary.isEmpty {
                            Text(score.touchSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let friendedOn = candidate.friendedOn {
                            Text("Friends since \(friendedOn.formatted(.dateTime.month(.abbreviated).year()))")
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

// MARK: - Preview

#Preview {
    FacebookImportReviewSheet(
        coordinator: FacebookImportCoordinator.shared,
        onDismiss: {}
    )
}
