import Foundation

public let AnalysisDerivedReasonPrefix = "Derived from analysis:"

public enum ArtifactToSignalsMapper {
  public static func signals(from artifact: NoteAnalysisArtifact, occurredAt: Date) -> [EvidenceSignal] {
      print("🔍 [ArtifactToSignalsMapper] Processing artifact:")
      print("   Summary: \(artifact.summary)")
      print("   Facts: \(artifact.facts)")
      print("   Implications: \(artifact.implications)")
      print("   Affect: \(artifact.affect ?? "nil")")
      print("   Topics: \(artifact.topics.count) (usedLLM: \(artifact.usedLLM))")
      print("   People: \(artifact.people.count)")
      
      var out: [EvidenceSignal] = []
      
      // ============================================================
      // PRIORITY 1: Use structured LLM data when available
      // ============================================================
      if artifact.usedLLM {
          // Generate signals from structured topics (high confidence)
          for topic in artifact.topics {
              let sentiment = topic.sentiment?.lowercased() ?? ""
              
              // Opportunity signals from wants/interests/increases
              if sentiment.contains("want") || sentiment.contains("interest") || 
                 sentiment.contains("increase") || sentiment.contains("consider") {
                  let confidence: Double = sentiment.contains("want") ? 0.85 : 0.75
                  let reason = "\(AnalysisDerivedReasonPrefix) Client interested in \(topic.productType)"
                  out.append(EvidenceSignal(
                      id: UUID(),
                      kind: .productOpportunity,
                      confidence: confidence,
                      reason: reason
                  ))
                  print("   ✅ Added opportunity signal from topic: \(topic.productType) (confidence: \(confidence))")
              }
              
              // Compliance risk for significant coverage amounts without documentation
              if let amount = topic.amount, 
                 amount.contains("$") {
                  let numericString = amount.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                  if let value = Int(numericString), value >= 50000 {
                      out.append(EvidenceSignal(
                          id: UUID(),
                          kind: .complianceRisk,
                          confidence: 0.60,
                          reason: "\(AnalysisDerivedReasonPrefix) High-value policy (\(amount)) requires documentation"
                      ))
                      print("   ✅ Added compliance risk signal for amount: \(amount)")
                  }
              }
          }
          
          // Generate signals from new people (opportunity to expand household)
          for person in artifact.people where person.isNewPerson {
              out.append(EvidenceSignal(
                  id: UUID(),
                  kind: .productOpportunity,
                  confidence: 0.70,
                  reason: "\(AnalysisDerivedReasonPrefix) New family member (\(person.name)) - coverage opportunity"
              ))
              print("   ✅ Added opportunity signal for new person: \(person.name)")
          }
          
          // Generate signals from actions
          for action in artifact.actions {
              let lower = action.lowercased()
              if lower.contains("follow") || lower.contains("schedule") || lower.contains("call") {
                  out.append(EvidenceSignal(
                      id: UUID(),
                      kind: .unlinkedEvidence,
                      confidence: 0.75,
                      reason: "\(AnalysisDerivedReasonPrefix) Action required: \(action)"
                  ))
                  print("   ✅ Added follow-up signal from action")
              }
          }
      }
      
      // ============================================================
      // PRIORITY 2: Fallback to heuristic keyword matching
      // ============================================================
      // Follow-up cues
      if artifact.facts.contains(where: { $0.localizedCaseInsensitiveContains("follow-up") || $0.localizedCaseInsensitiveContains("follow up") }) {
          out.append(EvidenceSignal(
              id: UUID(),
              kind: .unlinkedEvidence,
              confidence: 0.70,
              reason: "\(AnalysisDerivedReasonPrefix) Follow-up requested"
          ))
          print("   ✅ Added follow-up signal (heuristic)")
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
          print("   ✅ Added opportunity signal (heuristic, confidence: \(confidence))")
      }
      
      // Risk/concern cues -> complianceRisk for now
      if artifact.implications.contains(where: { $0.localizedCaseInsensitiveContains("risk") || $0.localizedCaseInsensitiveContains("concern") }) {
          out.append(EvidenceSignal(
              id: UUID(),
              kind: .complianceRisk,
              confidence: 0.62,
              reason: "\(AnalysisDerivedReasonPrefix) Potential risk/concern"
          ))
          print("   ✅ Added risk signal (heuristic)")
      }
      
      print("   📊 Total signals generated: \(out.count)")
      return out
  }
}
