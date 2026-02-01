import SwiftUI
import SwiftData

enum InsightKind: String {
    case consentMissing
    case followUp
    case relationshipAtRisk
    case opportunity
    case complianceWarning
}

protocol InsightDisplayable {
    var kind: InsightKind { get }
    var message: String { get }
    var confidence: Double { get }
    var interactionsCount: Int { get }
    var consentsCount: Int { get }
}

extension InsightDisplayable {
    var typeDisplayName: String {
        switch kind {
        case .consentMissing: return "Consent Missing"
        case .followUp: return "Follow Up"
        case .relationshipAtRisk: return "Relationship At Risk"
        case .opportunity: return "Opportunity"
        case .complianceWarning: return "Compliance Warning"
        }
    }
}

struct InsightCardView<I: InsightDisplayable>: View {
    let insight: I

    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            header

            if isExpanded {
                Divider()

                explanationSection
                evidenceSection
                actionsSection
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.15))
        )
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
    }
}

private extension InsightCardView {

    var header: some View {
        HStack(alignment: .top, spacing: 12) {

            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text(insight.message)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(insight.typeDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

private extension InsightCardView {

    var explanationSection: some View {
        VStack(alignment: .leading, spacing: 6) {

            Text("Why this is showing up")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(explanationText)
                .font(.callout)
                .foregroundStyle(.primary)

            if let confidenceText {
                Text(confidenceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var explanationText: String {
        switch insight.kind {
        case .consentMissing:
            return "An active product or relationship currently requires consent that has not been recorded."
        case .followUp:
            return "Recent interaction patterns suggest a follow-up may be helpful."
        case .relationshipAtRisk:
            return "Changes in interaction patterns may indicate a relationship change worth confirming."
        case .opportunity:
            return "Recent activity suggests a potential planning or coverage opportunity."
        case .complianceWarning:
            return "A structural or legal dependency may require review to remain compliant."
        }
    }

    var confidenceText: String? {
        guard insight.confidence < 0.95 else { return nil }
        return "Confidence: \(Int(insight.confidence * 100))%"
    }
}

private extension InsightCardView {

    var evidenceSection: some View {
        VStack(alignment: .leading, spacing: 6) {

            if hasEvidence {
                Text("Based on")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {

                    if insight.interactionsCount > 0 {
                        EvidenceRow(
                            icon: "bubble.left.and.bubble.right",
                            label: "\(insight.interactionsCount) interaction(s)"
                        )
                    }

                    if insight.consentsCount > 0 {
                        EvidenceRow(
                            icon: "checkmark.seal",
                            label: "\(insight.consentsCount) consent requirement(s)"
                        )
                    }
                }
            }
        }
    }

    var hasEvidence: Bool {
        (insight.interactionsCount > 0) || (insight.consentsCount > 0)
    }
}

private struct EvidenceRow: View {
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private extension InsightCardView {

    var actionsSection: some View {
        HStack(spacing: 12) {

            Button("Review") {
                // navigate to related context/person/product
            }

            Button("Remind Me Later") {
                // defer insight
            }

            Spacer()

            Button("Dismiss") {
                // mark dismissedAt
            }
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        .buttonStyle(.borderless)
    }
}

private extension InsightCardView {

    var iconName: String {
        switch insight.kind {
        case .consentMissing:
            return "checkmark.seal"
        case .followUp:
            return "arrow.turn.down.right"
        case .relationshipAtRisk:
            return "person.2.wave.2"
        case .opportunity:
            return "lightbulb"
        case .complianceWarning:
            return "exclamationmark.triangle"
        }
    }

    var iconColor: Color {
        switch insight.kind {
        case .complianceWarning:
            return .orange
        default:
            return .secondary
        }
    }
}

#Preview {
    struct MockInsight: InsightDisplayable {
        var kind: InsightKind
        var message: String
        var confidence: Double
        var interactionsCount: Int
        var consentsCount: Int
    }

    let insights: [MockInsight] = [
        .init(kind: .relationshipAtRisk,
              message: "Possible household structure change detected for John and Mary Smith.",
              confidence: 0.72,
              interactionsCount: 3,
              consentsCount: 0),
        .init(kind: .consentMissing,
              message: "Spousal consent is no longer valid for an active household policy.",
              confidence: 0.95,
              interactionsCount: 1,
              consentsCount: 2),
        .init(kind: .complianceWarning,
              message: "Household survivorship structure requires review following relationship change.",
              confidence: 0.88,
              interactionsCount: 2,
              consentsCount: 1)
    ]

    return VStack(spacing: 16) {
        ForEach(Array(insights.enumerated()), id: \.offset) { pair in
            InsightCardView(insight: pair.element)
        }
    }
    .padding()
    .frame(maxWidth: 520)
}
