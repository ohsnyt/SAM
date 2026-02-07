import Foundation

public enum ArtifactToSignalsMapper {
  public static func signals(from artifact: NoteAnalysisArtifact, occurredAt: Date) -> [EvidenceSignal] {
      var out: [EvidenceSignal] = []
      // Follow-up cues
      if artifact.facts.contains(where: { $0.localizedCaseInsensitiveContains("follow-up") || $0.localizedCaseInsensitiveContains("follow up") }) {
          out.append(EvidenceSignal(
              id: UUID(),
              kind: .unlinkedEvidence,
              confidence: 0.70,
              reason: "Derived from analysis: Follow-up requested"
          ))
      }
      // Opportunity cues
      if artifact.implications.contains(where: { $0.localizedCaseInsensitiveContains("opportunity") }) {
          out.append(EvidenceSignal(
              id: UUID(),
              kind: .productOpportunity,
              confidence: 0.65,
              reason: "Derived from analysis: Potential opportunity"
          ))
      }
      // Risk/concern cues -> complianceRisk for now
      if artifact.implications.contains(where: { $0.localizedCaseInsensitiveContains("risk") || $0.localizedCaseInsensitiveContains("concern") }) {
          out.append(EvidenceSignal(
              id: UUID(),
              kind: .complianceRisk,
              confidence: 0.62,
              reason: "Derived from analysis: Potential risk/concern"
          ))
      }
      // Affect can gently weight confidence (optional): keep simple for now.
      return out
  }
}
