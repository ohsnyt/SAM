//
//  SphereClassificationReviewSheet.swift
//  SAM
//
//  Phase C4 of the multi-sphere classification work (May 2026).
//
//  End-of-day review batch for mid-confidence classifier picks (the
//  0.5–0.75 band that didn't auto-apply). User sees:
//    • What the interaction was (title + snippet + when)
//    • Which sphere the classifier picked, plus a one-sentence reason
//    • Three actions: Accept, Pick different sphere, Dismiss
//
//  Designed for batch processing — short rows, primary "Accept" action,
//  keyboard nav so the user can rip through a queue quickly.
//
//  The sheet is not modal. Closing it leaves any unreviewed items
//  pending; they'll resurface the next time the user opens this batch.
//

import SwiftUI

struct SphereClassificationReviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var coordinator = SphereClassificationCoordinator.shared
    @State private var items: [SamEvidenceItem] = []
    @State private var spheres: [Sphere] = []
    @State private var staleEmpty: [Sphere] = []
    @State private var currentIndex: Int = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !staleEmpty.isEmpty {
                        staleEmptyBanner
                    }
                    if items.isEmpty {
                        emptyState
                    } else {
                        reviewBody
                    }
                }
            }
            .frame(width: 620, height: 540)
            .navigationTitle("Sphere review")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.escape)
                }
                if !items.isEmpty {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            skipThisWeek()
                        } label: {
                            Label("Skip this week", systemImage: "zzz")
                        }
                        .help("Hide sphere review for 7 days. SAM keeps queuing proposals in the background.")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Text("\(currentIndex + 1) of \(items.count)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task { reload() }
    }

    // MARK: - Stale empty banner

    private var staleEmptyBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("\(staleEmpty.count) sphere\(staleEmpty.count == 1 ? "" : "s") may not be earning its keep")
                    .font(.callout.weight(.semibold))
            }
            Text("Added 30+ days ago and still under 3 confirmed examples. Merge into another sphere, archive, or keep and SAM will ask again in 30 days.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(staleEmpty) { sphere in
                HStack(spacing: 8) {
                    Circle().fill(sphere.accentColor.color).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sphere.name).font(.callout.weight(.medium))
                        Text("\(sphere.examples.count) example\(sphere.examples.count == 1 ? "" : "s") · added \(sphere.createdAt.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Keep") { dismissStale(sphere) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Archive") { archiveStale(sphere) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.3)))
        .padding([.horizontal, .top], 16)
    }

    private func archiveStale(_ sphere: Sphere) {
        try? SphereRepository.shared.setArchived(id: sphere.id, true)
        staleEmpty.removeAll { $0.id == sphere.id }
    }

    /// "Keep for now" — snooze this sphere for 30 days. We re-evaluate
    /// using a UserDefaults date stamp keyed by the sphere ID so the
    /// banner won't pester the user again until the snooze expires.
    private func dismissStale(_ sphere: Sphere) {
        let key = "samSphereStaleSnooze.\(sphere.id.uuidString)"
        UserDefaults.standard.set(Date(), forKey: key)
        staleEmpty.removeAll { $0.id == sphere.id }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("All caught up")
                .font(.title3.weight(.semibold))
            Text("No interactions need sphere review right now. SAM will collect new ones in the background.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Review body

    private var reviewBody: some View {
        let item = items[currentIndex]
        let proposed = item.proposedSphereID.flatMap { id in
            spheres.first { $0.id == id }
        }
        let person = item.linkedPeople.first
        let cluster = clusterPeers(for: item)

        return VStack(alignment: .leading, spacing: 18) {
            // Person + when
            if let person {
                HStack(spacing: 8) {
                    Text(person.displayName)
                        .font(.title3.weight(.semibold))
                    Text("·").foregroundStyle(.secondary)
                    Text(item.occurredAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                }
            }

            // Bulk-confirm cluster: when N other pending items share this
            // person + proposed sphere on the same calendar day, offer one
            // action to confirm them all.
            if cluster.count >= 1, let proposed {
                clusterCard(peerCount: cluster.count, proposed: proposed, peers: cluster)
            }

            // Evidence card
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: sourceIcon(item.source))
                        .foregroundStyle(.secondary)
                    Text(item.title)
                        .font(.body.weight(.medium))
                }
                if !item.snippet.isEmpty {
                    Text(item.snippet)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            // Classifier proposal
            if let proposed {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("SAM thinks this belongs to")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        sphereBadge(proposed)
                        Text(confidenceLabel(item.proposedSphereConfidence))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let reason = item.proposedSphereReason, !reason.isEmpty {
                        Text(reason)
                            .font(.callout)
                            .foregroundStyle(.primary)
                    }
                }
            }

            Spacer(minLength: 0)

            // Actions
            actionRow(item: item, proposed: proposed)
        }
        .padding(24)
    }

    private func actionRow(item: SamEvidenceItem, proposed: Sphere?) -> some View {
        HStack(spacing: 12) {
            Button {
                coordinator.dismissProposal(evidenceID: item.id)
                advance()
            } label: {
                Label("Dismiss", systemImage: "xmark")
            }

            Menu {
                ForEach(otherSpheres(excluding: proposed)) { sphere in
                    Button {
                        coordinator.overrideProposal(evidenceID: item.id, with: sphere.id)
                        advance()
                    } label: {
                        HStack {
                            Circle().fill(sphere.accentColor.color).frame(width: 8, height: 8)
                            Text(sphere.name)
                        }
                    }
                }
            } label: {
                Label("Pick different…", systemImage: "list.bullet")
            }
            .disabled(otherSpheres(excluding: proposed).isEmpty)

            Spacer()

            Button {
                coordinator.acceptProposal(evidenceID: item.id)
                advance()
            } label: {
                Label("Accept", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(proposed == nil)
        }
    }

    // MARK: - Helpers

    private func reload() {
        let weekSnooze: TimeInterval = 7 * 24 * 60 * 60
        if let snoozedAt = UserDefaults.standard.object(forKey: Self.skipWeekKey) as? Date,
           Date().timeIntervalSince(snoozedAt) < weekSnooze {
            items = []
        } else {
            items = coordinator.pendingReviewItems()
        }
        spheres = (try? SphereRepository.shared.fetchAll()) ?? []
        let stale = (try? SphereRepository.shared.staleEmptySpheres()) ?? []
        let snoozeWindow: TimeInterval = 30 * 24 * 60 * 60
        staleEmpty = stale.filter { sphere in
            let key = "samSphereStaleSnooze.\(sphere.id.uuidString)"
            if let snoozedAt = UserDefaults.standard.object(forKey: key) as? Date,
               Date().timeIntervalSince(snoozedAt) < snoozeWindow {
                return false
            }
            return true
        }
        currentIndex = 0
    }

    // MARK: - Skip this week

    /// Defaults key for the user's "give me a week off" snooze on sphere
    /// classifier reviews. Resets after 7 days; survives app restarts.
    private static let skipWeekKey = "samSphereReviewSkipWeek"

    private func skipThisWeek() {
        UserDefaults.standard.set(Date(), forKey: Self.skipWeekKey)
        items = []
    }

    // MARK: - Bulk-confirm cluster

    /// Other pending items that share this item's linked person AND the
    /// classifier's proposed sphere AND fall on the same calendar day.
    /// Used to surface a "Confirm all N" affordance — the most common
    /// case (a thread or call burst with one person on one topic).
    private func clusterPeers(for item: SamEvidenceItem) -> [SamEvidenceItem] {
        guard let proposedID = item.proposedSphereID,
              let personID = item.linkedPeople.first?.id else { return [] }
        let cal = Calendar.current
        return items.filter { peer in
            guard peer.id != item.id else { return false }
            guard peer.proposedSphereID == proposedID else { return false }
            guard peer.linkedPeople.first?.id == personID else { return false }
            return cal.isDate(peer.occurredAt, inSameDayAs: item.occurredAt)
        }
    }

    @ViewBuilder
    private func clusterCard(peerCount: Int, proposed: Sphere, peers: [SamEvidenceItem]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "rectangle.stack.fill")
                .foregroundStyle(proposed.accentColor.color)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(peerCount + 1) interactions today look like \(proposed.name)")
                    .font(.callout.weight(.semibold))
                Text("Same person, same day, same classifier pick. Accept the whole cluster in one step.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Accept all \(peerCount + 1)") {
                acceptCluster(currentItem: items[currentIndex], peers: peers)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(proposed.accentColor.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(proposed.accentColor.color.opacity(0.25)))
    }

    private func acceptCluster(currentItem: SamEvidenceItem, peers: [SamEvidenceItem]) {
        let allIDs: [UUID] = [currentItem.id] + peers.map(\.id)
        let peerIDSet = Set(allIDs)
        for id in allIDs {
            coordinator.acceptProposal(evidenceID: id)
        }
        items.removeAll { peerIDSet.contains($0.id) }
        if currentIndex >= items.count {
            currentIndex = max(0, items.count - 1)
        }
    }

    private func advance() {
        // Removing the just-handled item keeps `items.count` accurate
        // for the position indicator and avoids stale snapshots that
        // could re-render the same row after `clearProposal` ran.
        guard !items.isEmpty else { return }
        items.remove(at: currentIndex)
        if currentIndex >= items.count {
            currentIndex = max(0, items.count - 1)
        }
    }

    private func otherSpheres(excluding proposed: Sphere?) -> [Sphere] {
        guard let proposed else { return spheres }
        return spheres.filter { $0.id != proposed.id }
    }

    private func sphereBadge(_ sphere: Sphere) -> some View {
        HStack(spacing: 6) {
            Circle().fill(sphere.accentColor.color).frame(width: 8, height: 8)
            Text(sphere.name).font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(sphere.accentColor.color.opacity(0.15), in: Capsule())
    }

    private func confidenceLabel(_ confidence: Double) -> String {
        let pct = Int((confidence * 100).rounded())
        return "(\(pct)% confidence)"
    }

    private func sourceIcon(_ source: EvidenceSource) -> String {
        switch source {
        case .calendar: return "calendar"
        case .mail, .sentMail: return "envelope"
        case .iMessage, .whatsApp, .zoomChat: return "message"
        case .phoneCall, .faceTime, .whatsAppCall: return "phone"
        case .note, .voiceCapture, .meetingTranscript: return "note.text"
        case .linkedIn, .facebook, .substack: return "globe"
        default: return "doc.text"
        }
    }
}
