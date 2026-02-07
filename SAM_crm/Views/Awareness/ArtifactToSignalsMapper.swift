import Foundation

public let AnalysisDerivedReasonPrefix = "Derived from analysis:"

public enum ArtifactToSignalsMapper {
  public static func signals(from artifact: NoteAnalysisArtifact, occurredAt: Date) -> [EvidenceSignal] {
      print("🔍 [ArtifactToSignalsMapper] Processing artifact:")
      print("   Summary: \(artifact.summary)")
      print("   Facts: \(artifact.facts)")
      print("   Implications: \(artifact.implications)")
      print("   Affect: \(artifact.affect ?? "nil")")
      
      var out: [EvidenceSignal] = []
      // Follow-up cues
      if artifact.facts.contains(where: { $0.localizedCaseInsensitiveContains("follow-up") || $0.localizedCaseInsensitiveContains("follow up") }) {
          out.append(EvidenceSignal(
              id: UUID(),
              kind: .unlinkedEvidence,
              confidence: 0.70,
              reason: "\(AnalysisDerivedReasonPrefix) Follow-up requested"
          ))
          print("   ✅ Added follow-up signal")
      }
      // Opportunity cues - with higher confidence for explicit product mentions
      let hasExplicitProduct = artifact.implications.contains(where: { impl in
          let lower = impl.lowercased()
          return lower.contains("life insurance") || lower.contains("retirement") || 
                 lower.contains("policy") || lower.contains("annuity") ||
                 lower.contains("401k") || lower.contains("ira")
      })
      
      if artifact.implications.contains(where: { $0.localizedCaseInsensitiveContains("opportunity") }) {
          let confidence = hasExplicitProduct ? 0.75 : 0.65
          out.append(EvidenceSignal(
              id: UUID(),
              kind: .productOpportunity,
              confidence: confidence,
              reason: "\(AnalysisDerivedReasonPrefix) Potential opportunity"
          ))
          print("   ✅ Added opportunity signal (confidence: \(confidence))")
      }
      // Risk/concern cues -> complianceRisk for now
      if artifact.implications.contains(where: { $0.localizedCaseInsensitiveContains("risk") || $0.localizedCaseInsensitiveContains("concern") }) {
          out.append(EvidenceSignal(
              id: UUID(),
              kind: .complianceRisk,
              confidence: 0.62,
              reason: "\(AnalysisDerivedReasonPrefix) Potential risk/concern"
          ))
          print("   ✅ Added risk signal")
      }
      
      print("   📊 Total signals generated: \(out.count)")
      // Affect can gently weight confidence (optional): keep simple for now.
      return out
  }
}
