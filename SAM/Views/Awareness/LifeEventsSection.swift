//
//  LifeEventsSection.swift
//  SAM
//
//  Created by Assistant on 2/24/26.
//
//  Awareness dashboard section surfacing life events detected in notes
//  with outreach suggestions. Mark as acted-on when done.
//

import SwiftUI
import SwiftData

struct LifeEventsSection: View {

    @Query(sort: \SamNote.createdAt, order: .reverse)
    private var allNotes: [SamNote]

    @State private var dismissedIDs: Set<UUID> = []

    /// Flatten all pending life events from notes, paired with their source note.
    private var pendingEvents: [(event: LifeEvent, note: SamNote)] {
        allNotes.flatMap { note in
            note.lifeEvents
                .filter { $0.status == .pending && !dismissedIDs.contains($0.id) }
                .map { (event: $0, note: note) }
        }
    }

    var body: some View {
        if !pendingEvents.isEmpty {
            VStack(spacing: 0) {
                // Section header
                HStack {
                    Image(systemName: "heart.circle")
                        .foregroundStyle(.pink)
                    Text("Life Events")
                        .font(.headline)
                    Text("\(pendingEvents.count)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.pink)
                        .clipShape(Capsule())
                    Spacer()
                    Text("Outreach opportunities")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)

                Divider()

                LazyVStack(spacing: 8) {
                    ForEach(pendingEvents, id: \.event.id) { item in
                        LifeEventCard(
                            event: item.event,
                            note: item.note,
                            onDone: {
                                markActedOn(event: item.event, note: item.note)
                            },
                            onDismiss: {
                                withAnimation { () -> Void in
                                    dismissedIDs.insert(item.event.id)
                                }
                            }
                        )
                    }
                }
                .padding()
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private func markActedOn(event: LifeEvent, note: SamNote) {
        try? NotesRepository.shared.updateLifeEvent(
            note: note,
            lifeEventID: event.id,
            status: .actedOn
        )
    }
}

// MARK: - Life Event Card

private struct LifeEventCard: View {

    let event: LifeEvent
    let note: SamNote
    let onDone: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: person name + event badge
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconForEventType(event.eventType))
                    .foregroundStyle(.pink)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    // Person name (tappable)
                    HStack(spacing: 6) {
                        Button(action: navigateToPerson) {
                            Text(event.personName)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)

                        Text(event.eventTypeLabel)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.pink.opacity(0.15))
                            .foregroundStyle(.pink)
                            .clipShape(Capsule())
                    }

                    // Description
                    Text(event.eventDescription)
                        .font(.subheadline)
                        .foregroundStyle(.primary)

                    // Approximate date
                    if let approxDate = event.approximateDate, !approxDate.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(approxDate)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Outreach suggestion
                    if let suggestion = event.outreachSuggestion, !suggestion.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "lightbulb")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Text(suggestion)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                            Spacer()
                            CopyButton(text: suggestion)
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                Spacer()
            }

            // Actions
            HStack(spacing: 10) {
                Button(action: onDone) {
                    Label("Done", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .controlSize(.small)

                Button(action: onDismiss) {
                    Label("Skip", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.pink.opacity(0.3), lineWidth: 1)
        )
    }

    private func navigateToPerson() {
        // Find matching person by name from the note's linked people
        let matchedPerson = note.linkedPeople.first { person in
            let displayName = person.displayNameCache ?? person.displayName
            return displayName.lowercased() == event.personName.lowercased()
        } ?? note.linkedPeople.first

        guard let personID = matchedPerson?.id else { return }
        NotificationCenter.default.post(
            name: .samNavigateToPerson,
            object: nil,
            userInfo: ["personID": personID]
        )
    }

    private func iconForEventType(_ type: String) -> String {
        switch type {
        case "new_baby": return "stroller"
        case "marriage": return "heart.fill"
        case "graduation": return "graduationcap"
        case "job_change": return "briefcase"
        case "retirement": return "sun.horizon"
        case "moving": return "house"
        case "health_issue": return "cross.case"
        case "promotion": return "star.fill"
        case "anniversary": return "gift"
        case "loss": return "leaf"
        default: return "heart.circle"
        }
    }
}
