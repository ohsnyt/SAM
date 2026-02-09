import SwiftUI
import SwiftData
import Contacts

/// Smart suggestion card that analyzes artifact data and proposes comprehensive actions
/// Shows life events, relationship updates, and communication suggestions
struct SmartSuggestionCard: View {
    let artifact: SamAnalysisArtifact
    let linkedPeople: [SamPerson]
    let noteText: String
    
    let onAcceptAll: (SuggestionActions) -> Void
    let onAcceptAndEdit: (SuggestionActions) -> Void
    let onSkip: () -> Void
    
    @State private var suggestedActions: SuggestionActions?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.blue)
                Text("SAM Suggestions")
                    .font(.headline)
                Spacer()
            }
            
            if let actions = suggestedActions {
                VStack(alignment: .leading, spacing: 12) {
                    // Contact Updates
                    if !actions.contactUpdates.isEmpty {
                        SuggestionSection(
                            title: "Contact Updates",
                            icon: "person.badge.plus",
                            color: .blue
                        ) {
                            ForEach(actions.contactUpdates, id: \.description) { update in
                                Text(update.description)
                                    .font(.callout)
                            }
                        }
                    }
                    
                    // Note Updates
                    if let noteUpdate = actions.noteUpdate {
                        SuggestionSection(
                            title: "Summary Note",
                            icon: "note.text",
                            color: .purple
                        ) {
                            Text(noteUpdate)
                                .font(.callout)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                                .background(.purple.opacity(0.05))
                                .cornerRadius(8)
                        }
                    }
                    
                    // Communication Suggestions
                    if !actions.messages.isEmpty {
                        SuggestionSection(
                            title: "Send Congratulations",
                            icon: "paperplane",
                            color: .green
                        ) {
                            ForEach(actions.messages, id: \.type) { message in
                                MessagePreview(message: message)
                            }
                        }
                    }
                    
                    // Action Buttons
                    HStack(spacing: 12) {
                        Button {
                            onAcceptAll(actions)
                        } label: {
                            Label("Apply All", systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Button {
                            onAcceptAndEdit(actions)
                        } label: {
                            Label("Apply & Edit", systemImage: "pencil.circle")
                        }
                        .buttonStyle(.bordered)
                        
                        Button("Skip for Now") {
                            onSkip()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 8)
                }
            } else {
                ProgressView("Analyzing...")
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .cornerRadius(12)
        .task {
            suggestedActions = await generateSuggestions()
        }
    }
    
    private func generateSuggestions() async -> SuggestionActions {
        var contactUpdates: [ContactUpdate] = []
        var messages: [SuggestedMessage] = []
        var noteUpdate: String?
        
        // Detect new family members
        for person in artifact.people where person.isNewPerson {
            if let relationship = person.relationship,
               !relationship.isEmpty,
               let parent = linkedPeople.first {
                contactUpdates.append(
                    ContactUpdate(
                        type: .addFamilyMember,
                        personName: person.name,
                        relationship: relationship,
                        targetPerson: parent,
                        description: "Add \(person.name) as \(parent.displayNameCache ?? "contact")'s \(relationship)"
                    )
                )
            }
        }
        
        // Detect life events and financial requests
        let lifeEvents = detectLifeEvents(from: noteText, artifact: artifact)
        
        // Build comprehensive summary note
        if !lifeEvents.isEmpty || !artifact.topics.isEmpty {
            noteUpdate = buildSummaryNote(
                lifeEvents: lifeEvents,
                topics: artifact.topics,
                people: artifact.people
            )
        }
        
        // Generate congratulations messages
        for event in lifeEvents {
            if let message = generateCongratulationsMessage(
                event: event,
                person: linkedPeople.first
            ) {
                messages.append(message)
            }
        }
        
        return SuggestionActions(
            contactUpdates: contactUpdates,
            noteUpdate: noteUpdate,
            messages: messages
        )
    }
    
    private func detectLifeEvents(from text: String, artifact: SamAnalysisArtifact) -> [LifeEvent] {
        var events: [LifeEvent] = []
        let lower = text.lowercased()
        
        // Detect birth
        if lower.contains("had a daughter") || lower.contains("had a son") || lower.contains("new baby") {
            for person in artifact.people where person.isNewPerson {
                if let rel = person.relationship?.lowercased(),
                   rel.contains("daughter") || rel.contains("son") || rel.contains("child") {
                    events.append(LifeEvent(
                        type: .birth,
                        personName: person.name,
                        details: "Birth of \(person.name)"
                    ))
                }
            }
        }
        
        // Detect bonus/promotion
        if lower.contains("bonus") || lower.contains("promotion") || lower.contains("raise") {
            events.append(LifeEvent(
                type: .workSuccess,
                personName: linkedPeople.first?.displayNameCache ?? "Client",
                details: "Received bonus at work"
            ))
        }
        
        return events
    }
    
    private func buildSummaryNote(
        lifeEvents: [LifeEvent],
        topics: [StoredFinancialTopicEntity],
        people: [StoredPersonEntity]
    ) -> String {
        var parts: [String] = []
        
        // Life events
        for event in lifeEvents {
            switch event.type {
            case .birth:
                parts.append("👶 \(event.personName) was born (approx. \(Date().formatted(date: .abbreviated, time: .omitted)))")
            case .workSuccess:
                parts.append("🎉 \(event.details)")
            }
        }
        
        // Financial requests
        for topic in topics {
            var topicPart = "💼 Interest in \(topic.productType)"
            if let amount = topic.amount, amount > 0 {
                topicPart += " ($\(formatCurrency(amount)))"
            }
            if let beneficiary = topic.beneficiary {
                topicPart += " for \(beneficiary)"
            }
            parts.append(topicPart)
        }
        
        return parts.joined(separator: "\n")
    }
    
    private func generateCongratulationsMessage(
        event: LifeEvent,
        person: SamPerson?
    ) -> SuggestedMessage? {
        guard let person = person else { return nil }
        let firstName = person.displayNameCache?.components(separatedBy: " ").first ?? "there"
        
        switch event.type {
        case .birth:
            return SuggestedMessage(
                type: .sms,
                subject: nil,
                body: "Hi \(firstName)! Congratulations on the birth of \(event.personName)! 🎉👶 This is such wonderful news. I'm so happy for you and your family. Let me know if there's anything I can do to help during this exciting time!",
                recipient: person.emailCache ?? ""
            )
        case .workSuccess:
            return SuggestedMessage(
                type: .sms,
                subject: nil,
                body: "Hi \(firstName)! Congratulations on your bonus! 🎉 That's fantastic news and well-deserved. Great work!",
                recipient: person.emailCache ?? ""
            )
        }
    }
    
    private func formatCurrency(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: amount)) ?? "\(Int(amount))"
    }
}

// MARK: - Supporting Views

struct SuggestionSection<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            
            content
                .padding(.leading, 24)
        }
    }
}

struct MessagePreview: View {
    let message: SuggestedMessage
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: message.type == .sms ? "message" : "envelope")
                        .foregroundStyle(.green)
                    Text(message.type == .sms ? "Text Message" : "Email")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let subject = message.subject {
                        Text("Subject: \(subject)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Text(message.body)
                        .font(.callout)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(.green.opacity(0.05))
                        .cornerRadius(8)
                    
                    Text("To: \(message.recipient)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Data Models

struct SuggestionActions {
    let contactUpdates: [ContactUpdate]
    let noteUpdate: String?
    let messages: [SuggestedMessage]
}

struct ContactUpdate {
    enum UpdateType {
        case addFamilyMember
        case updateInfo
    }
    
    let type: UpdateType
    let personName: String
    let relationship: String
    let targetPerson: SamPerson
    let description: String
}

struct SuggestedMessage {
    enum MessageType {
        case sms
        case email
    }
    
    let type: MessageType
    let subject: String?
    let body: String
    let recipient: String
}

struct LifeEvent {
    enum EventType {
        case birth
        case workSuccess
    }
    
    let type: EventType
    let personName: String
    let details: String
}
