import SwiftUI
import SwiftData

/// Displays LLM-extracted entities from a SamAnalysisArtifact
/// Shows people, topics, facts, and implications with actionable UI
struct AnalysisArtifactCard: View {
    let artifact: SamAnalysisArtifact
    let onCreateContact: (StoredPersonEntity) -> Void
    
    @State private var expandedSections: Set<String> = []
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Label("AI Analysis", systemImage: artifact.usedLLM ? "brain" : "text.magnifyingglass")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                if artifact.usedLLM {
                    Text("On-Device LLM")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.1))
                        .clipShape(Capsule())
                } else {
                    Text("Heuristic")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
            
            Divider()
            
            // People Section
            if !artifact.people.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        toggleSection("people")
                    } label: {
                        HStack {
                            Label("People (\(artifact.people.count))", systemImage: "person.2")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: expandedSections.contains("people") ? "chevron.down" : "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    
                    if expandedSections.contains("people") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(artifact.people, id: \.name) { person in
                                PersonEntityRow(person: person, onCreateContact: onCreateContact)
                            }
                        }
                        .padding(.leading, 24)
                    }
                }
            }
            
            // Topics Section
            if !artifact.topics.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        toggleSection("topics")
                    } label: {
                        HStack {
                            Label("Financial Topics (\(artifact.topics.count))", systemImage: "dollarsign.circle")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: expandedSections.contains("topics") ? "chevron.down" : "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    
                    if expandedSections.contains("topics") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(artifact.topics, id: \.productType) { topic in
                                TopicEntityRow(topic: topic)
                            }
                        }
                        .padding(.leading, 24)
                    }
                }
            }
            
            // Facts Section
            if !artifact.facts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        toggleSection("facts")
                    } label: {
                        HStack {
                            Label("Facts (\(artifact.facts.count))", systemImage: "checkmark.circle")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: expandedSections.contains("facts") ? "chevron.down" : "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    
                    if expandedSections.contains("facts") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(artifact.facts, id: \.self) { fact in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•")
                                        .foregroundStyle(.secondary)
                                    Text(fact)
                                        .font(.callout)
                                }
                            }
                        }
                        .padding(.leading, 24)
                    }
                }
            }
            
            // Implications Section
            if !artifact.implications.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        toggleSection("implications")
                    } label: {
                        HStack {
                            Label("Implications (\(artifact.implications.count))", systemImage: "lightbulb")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: expandedSections.contains("implications") ? "chevron.down" : "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    
                    if expandedSections.contains("implications") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(artifact.implications, id: \.self) { implication in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•")
                                        .foregroundStyle(.secondary)
                                    Text(implication)
                                        .font(.callout)
                                }
                            }
                        }
                        .padding(.leading, 24)
                    }
                }
            }
            
            // Actions Section
            if !artifact.actions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        toggleSection("actions")
                    } label: {
                        HStack {
                            Label("Action Items (\(artifact.actions.count))", systemImage: "list.bullet.clipboard")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: expandedSections.contains("actions") ? "chevron.down" : "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    
                    if expandedSections.contains("actions") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(artifact.actions, id: \.self) { action in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("→")
                                        .foregroundStyle(.blue)
                                    Text(action)
                                        .font(.callout)
                                }
                            }
                        }
                        .padding(.leading, 24)
                    }
                }
            }
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    private func toggleSection(_ section: String) {
        if expandedSections.contains(section) {
            expandedSections.remove(section)
        } else {
            expandedSections.insert(section)
        }
    }
}

struct PersonEntityRow: View {
    let person: StoredPersonEntity
    let onCreateContact: (StoredPersonEntity) -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: person.isNewPerson ? "person.badge.plus" : "person")
                .foregroundStyle(person.isNewPerson ? .blue : .secondary)
                .font(.body)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(person.name)
                        .font(.callout)
                    
                    if person.isNewPerson {
                        Text("NEW")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.blue)
                            .clipShape(Capsule())
                    }
                }
                
                if let relationship = person.relationship {
                    Text(relationship.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                if !person.aliases.isEmpty {
                    Text("Also: \(person.aliases.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            
            Spacer()
            
            if person.isNewPerson {
                Button {
                    onCreateContact(person)
                } label: {
                    Label("Add Contact", systemImage: "plus.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .help("Create a new contact for \(person.name)")
            }
        }
        .padding(.vertical, 4)
    }
}

struct TopicEntityRow: View {
    let topic: StoredFinancialTopicEntity
    
    private var icon: String {
        let lower = topic.productType.lowercased()
        if lower.contains("life insurance") || lower.contains("policy") {
            return "cross.case"
        } else if lower.contains("retirement") || lower.contains("401k") || lower.contains("ira") {
            return "chart.line.uptrend.xyaxis"
        } else if lower.contains("annuity") {
            return "calendar.badge.clock"
        } else {
            return "dollarsign.circle"
        }
    }
    
    private var sentimentColor: Color {
        guard let sentiment = topic.sentiment?.lowercased() else { return .secondary }
        if sentiment.contains("want") || sentiment.contains("interest") {
            return .green
        } else if sentiment.contains("increase") {
            return .blue
        } else if sentiment.contains("consider") {
            return .orange
        } else if sentiment.contains("not interest") || sentiment.contains("cancel") {
            return .red
        }
        return .secondary
    }
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .font(.body)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(topic.productType)
                        .font(.callout)
                    
                    if let amount = topic.amount {
                        Text(amount)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                }
                
                HStack(spacing: 8) {
                    if let beneficiary = topic.beneficiary {
                        Text("For: \(beneficiary)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    if let sentiment = topic.sentiment {
                        Text(sentiment.capitalized)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(sentimentColor)
                    }
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview("Artifact with LLM Data") {
    AnalysisArtifactCard(
        artifact: SamAnalysisArtifact(
            sourceKind: .note,
            summary: "Discussed life insurance for new child",
            facts: ["Follow-up requested"],
            implications: ["Potential opportunity: Life Insurance for Frank", "New person identified: Frank"],
            affect: .neutral,
            people: [
                StoredPersonEntity(name: "Frank", relationship: "son", aliases: ["Frankie"], isNewPerson: true),
                StoredPersonEntity(name: "Advisor", relationship: "Financial Advisor", isNewPerson: false)
            ],
            topics: [
                StoredFinancialTopicEntity(
                    productType: "Life Insurance",
                    amount: "$60,000",
                    beneficiary: "Frank",
                    sentiment: "wants"
                ),
                StoredFinancialTopicEntity(
                    productType: "Indexed Universal Life Insurance",
                    amount: nil,
                    beneficiary: "Advisor",
                    sentiment: "increase"
                )
            ],
            actions: ["Discuss Frank's life insurance policy", "Increase IUL"],
            usedLLM: true
        ),
        onCreateContact: { person in
            print("Create contact for: \(person.name)")
        }
    )
    .padding()
    .frame(width: 500)
}

#Preview("Artifact Heuristic Only") {
    AnalysisArtifactCard(
        artifact: SamAnalysisArtifact(
            sourceKind: .note,
            summary: "Meeting notes",
            facts: ["Follow-up requested"],
            implications: ["Potential opportunity"],
            affect: .positive,
            usedLLM: false
        ),
        onCreateContact: { _ in }
    )
    .padding()
    .frame(width: 500)
}
