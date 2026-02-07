import Foundation

public struct NoteSignal {
    public enum Kind: String {
        case followUp
        case opportunity
        case sentimentPositive
        case sentimentNegative
        case other
    }
    
    public let kind: Kind
    public let confidence: Double
    public let rationale: String
}

public enum NoteAnalyzer {
    // Extremely simple heuristics placeholder; real implementation should use existing InsightGenerator or improved rules.
    public static func analyze(text: String) -> [NoteSignal] {
        let lower = text.lowercased()
        var results: [NoteSignal] = []
        
        if lower.contains("follow up") || lower.contains("follow-up") {
            results.append(NoteSignal(kind: .followUp, confidence: 0.8, rationale: "Contains phrase 'follow up'"))
        }
        
        if lower.contains("opportunity") || lower.contains("interested") {
            results.append(NoteSignal(kind: .opportunity, confidence: 0.6, rationale: "Contains opportunity cues"))
        }
        
        if lower.contains(":)") || lower.contains("great meeting") {
            results.append(NoteSignal(kind: .sentimentPositive, confidence: 0.55, rationale: "Positive sentiment cues"))
        }
        
        if lower.contains(":(") || lower.contains("concern") {
            results.append(NoteSignal(kind: .sentimentNegative, confidence: 0.55, rationale: "Negative sentiment cues"))
        }
        
        if results.isEmpty {
            results.append(NoteSignal(kind: .other, confidence: 0.3, rationale: "No specific cues detected"))
        }
        
        return results
    }
}
