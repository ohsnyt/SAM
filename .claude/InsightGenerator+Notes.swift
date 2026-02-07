import Foundation

public actor InsightGeneratorNotesAdapter {
  public static let shared = InsightGeneratorNotesAdapter()
  private init() {}

  // Entry point to analyze a note and trigger insight generation pipeline
  public func analyzeNote(text: String, noteID: UUID?) async {
      // TODO: Replace with real local AI extraction for facts, affect, implications.
      // For now, simply kick the existing DebouncedInsightRunner to re-run generation
      await DebouncedInsightRunner.shared.kick()
  }
}
