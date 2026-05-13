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
    @State private var currentIndex: Int = 0

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    emptyState
                } else {
                    reviewBody
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
        items = coordinator.pendingReviewItems()
        spheres = (try? SphereRepository.shared.fetchAll()) ?? []
        currentIndex = 0
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
