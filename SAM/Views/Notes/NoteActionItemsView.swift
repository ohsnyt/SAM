//
//  NoteActionItemsView.swift
//  SAM_crm
//
//  Created by Assistant on 2/11/26.
//  Phase H: Notes & Note Intelligence
//
//  Review and act on AI-extracted action items from notes.
//

import SwiftUI
import SwiftData

struct NoteActionItemsView: View {
    
    // MARK: - Parameters
    
    let note: SamNote
    
    // MARK: - Dependencies
    
    @State private var repository = NotesRepository.shared
    
    // MARK: - State
    
    @State private var expandedItems: Set<UUID> = []
    
    // MARK: - Body
    
    var body: some View {
        List {
            if note.extractedActionItems.isEmpty {
                ContentUnavailableView {
                    Label("No Action Items", systemImage: "checklist")
                } description: {
                    Text("AI analysis did not identify any actionable items in this note")
                }
            } else {
                ForEach(Array(note.extractedActionItems.enumerated()), id: \.offset) { _, item in
                    ActionItemRow(
                        item: item,
                        isExpanded: expandedItems.contains(item.id),
                        onToggleExpand: {
                            toggleExpanded(item.id)
                        },
                        onUpdateStatus: { newStatus in
                            updateItemStatus(item.id, status: newStatus)
                        }
                    )
                }
            }
        }
        .navigationTitle("Action Items")
    }
    
    // MARK: - Actions
    
    private func toggleExpanded(_ itemID: UUID) {
        if expandedItems.contains(itemID) {
            expandedItems.remove(itemID)
        } else {
            expandedItems.insert(itemID)
        }
    }
    
    private func updateItemStatus(_ itemID: UUID, status: NoteActionItem.ActionStatus) {
        Task {
            do {
                try repository.updateActionItem(note: note, actionItemID: itemID, status: status)
            } catch {
                // Action item update error — will revert on next load
            }
        }
    }
}

// MARK: - Action Item Row

private struct ActionItemRow: View {
    let item: NoteActionItem
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onUpdateStatus: (NoteActionItem.ActionStatus) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                // Type icon
                Image(systemName: item.type.icon)
                    .foregroundStyle(item.type.color)
                    .frame(width: 24)
                
                // Description
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.description)
                        .font(.body)
                    
                    HStack(spacing: 8) {
                        // Type badge
                        Text(item.type.displayName)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(item.type.color.opacity(0.2))
                            .foregroundStyle(item.type.color)
                            .clipShape(Capsule())
                        
                        // Urgency badge
                        Text(item.urgency.displayName)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(item.urgency.color.opacity(0.2))
                            .foregroundStyle(item.urgency.color)
                            .clipShape(Capsule())
                        
                        // Status badge
                        Text(item.status.displayName)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(item.status.color.opacity(0.2))
                            .foregroundStyle(item.status.color)
                            .clipShape(Capsule())
                    }
                }
                
                Spacer()
                
                // Expand button
                Button(action: onToggleExpand) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    
                    // Person link
                    if let personName = item.linkedPersonName {
                        HStack {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.secondary)
                            Text("Related to: \(personName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    // Suggested text (for messages)
                    if let suggestedText = item.suggestedText {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Suggested Message:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            Text(suggestedText)
                                .font(.body)
                                .padding(8)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    
                    // Actions
                    HStack(spacing: 12) {
                        if item.status == .pending {
                            Button(action: {
                                onUpdateStatus(.completed)
                            }) {
                                Label("Complete", systemImage: "checkmark.circle")
                            }
                            .buttonStyle(.bordered)
                            .tint(.green)
                            
                            Button(action: {
                                onUpdateStatus(.dismissed)
                            }) {
                                Label("Dismiss", systemImage: "xmark.circle")
                            }
                            .buttonStyle(.bordered)
                            .tint(.secondary)
                        } else {
                            Button(action: {
                                onUpdateStatus(.pending)
                            }) {
                                Label("Reopen", systemImage: "arrow.counterclockwise")
                            }
                            .buttonStyle(.bordered)
                        }
                        
                        // Action-specific buttons
                        if item.type == .sendCongratulations || item.type == .sendReminder {
                            if let channel = item.suggestedChannel {
                                Button(action: {
                                    // TODO: Open compose sheet for message
                                }) {
                                    Label("Send \(channel.displayName)", systemImage: channel.icon)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Display Extensions

extension NoteActionItem.ActionType {
    var displayName: String {
        switch self {
        case .updateContact: return "Update Contact"
        case .sendCongratulations: return "Send Congratulations"
        case .sendReminder: return "Send Reminder"
        case .scheduleMeeting: return "Schedule Meeting"
        case .createProposal: return "Create Proposal"
        case .updateBeneficiary: return "Update Beneficiary"
        case .generalFollowUp: return "Follow Up"
        }
    }
    
    var icon: String {
        switch self {
        case .updateContact: return "person.badge.plus"
        case .sendCongratulations: return "gift"
        case .sendReminder: return "bell"
        case .scheduleMeeting: return "calendar.badge.plus"
        case .createProposal: return "doc.badge.plus"
        case .updateBeneficiary: return "person.2"
        case .generalFollowUp: return "arrow.turn.up.right"
        }
    }
    
    var color: Color {
        switch self {
        case .updateContact: return .blue
        case .sendCongratulations: return .pink
        case .sendReminder: return .orange
        case .scheduleMeeting: return .purple
        case .createProposal: return .green
        case .updateBeneficiary: return .indigo
        case .generalFollowUp: return .teal
        }
    }
}

extension NoteActionItem.Urgency {
    var displayName: String {
        switch self {
        case .immediate: return "Immediate"
        case .soon: return "Soon"
        case .standard: return "Standard"
        case .low: return "Low"
        }
    }
    
    var color: Color {
        switch self {
        case .immediate: return .red
        case .soon: return .orange
        case .standard: return .blue
        case .low: return .gray
        }
    }
}

extension NoteActionItem.ActionStatus {
    var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .completed: return "Completed"
        case .dismissed: return "Dismissed"
        }
    }
    
    var color: Color {
        switch self {
        case .pending: return .orange
        case .completed: return .green
        case .dismissed: return .gray
        }
    }
}

extension NoteActionItem.MessageChannel {
    var displayName: String {
        switch self {
        case .sms: return "SMS"
        case .email: return "Email"
        case .phone: return "Phone"
        }
    }
    
    var icon: String {
        switch self {
        case .sms: return "message"
        case .email: return "envelope"
        case .phone: return "phone"
        }
    }
}

// MARK: - Preview

#Preview {
    let container = SAMModelContainer.shared
    let context = ModelContext(container)
    
    let note = SamNote(
        content: "Met with John and Sarah Smith. New baby Emma born Jan 15.",
        summary: "Discussed life insurance for growing family"
    )
    
    note.extractedActionItems = [
        NoteActionItem(
            type: .sendCongratulations,
            description: "Congratulate John and Sarah on the birth of Emma",
            suggestedText: "John and Sarah — congratulations on the arrival of baby Emma! What wonderful news. Wishing your growing family all the best.",
            suggestedChannel: .sms,
            urgency: .soon,
            linkedPersonName: "John Smith",
            status: .pending
        ),
        NoteActionItem(
            type: .updateContact,
            description: "Add Emma as child of John and Sarah Smith",
            urgency: .standard,
            linkedPersonName: "John Smith",
            status: .pending
        ),
        NoteActionItem(
            type: .scheduleMeeting,
            description: "Follow up with Smith family in 3 weeks",
            urgency: .standard,
            linkedPersonName: "John Smith",
            status: .pending
        )
    ]
    
    context.insert(note)
    
    return NavigationStack {
        NoteActionItemsView(note: note)
    }
    .modelContainer(container)
    .frame(width: 500, height: 600)
}
