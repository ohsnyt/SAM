import SwiftUI

public struct AddNoteForPeopleView: View {
    public struct PersonItem: Identifiable, Hashable {
        public let id: UUID
        public let displayName: String
    }
    @State private var text: String = ""
    @State private var selected: Set<UUID> = []
    @Binding var isProcessing: Bool  // Phase 1.1: Bind to external processing state
    
    public let people: [PersonItem]
    public var onSave: (_ text: String, _ selectedPeopleIDs: [UUID]) -> Void
    @Environment(\.dismiss) private var dismiss

    public init(
        people: [PersonItem],
        isProcessing: Binding<Bool> = .constant(false),  // Phase 1.1: Optional binding with default
        onSave: @escaping (_ text: String, _ selectedPeopleIDs: [UUID]) -> Void
    ) {
        self.people = people
        self._isProcessing = isProcessing
        self.onSave = onSave
        // Pre-select all provided people when sheet opens
        self._selected = State(initialValue: Set(people.map { $0.id }))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header and content
            VStack(alignment: .leading, spacing: 12) {
                Text("Add Note").font(.title2).bold()
                Text("Select one or more people and enter a note. SAM will analyze it to surface insights.")
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 16) {
                    List(selection: $selected) {
                        ForEach(people) { p in
                            Text(p.displayName).tag(p.id)
                        }
                    }
                    .frame(minWidth: 220, minHeight: 220)

                    TextEditor(text: $text)
                        .font(.body)
                        .frame(minHeight: 220)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                }

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .disabled(isProcessing)  // Phase 1.1: Disable during processing
                    Button("Save") {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        
                        // Phase 1.1: Set processing state before saving
                        isProcessing = true
                        
                        onSave(trimmed, Array(selected))
                        
                        // Don't dismiss - let the caller dismiss when processing completes
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing)
                }
            }
            .padding()
            
            // Phase 1.1: Processing indicator at bottom
            NoteProcessingIndicator(isProcessing: isProcessing)
                .padding(.bottom, isProcessing ? 12 : 0)
        }
        .frame(minWidth: 640)
        .onChange(of: isProcessing) { _, newValue in
            // Dismiss sheet after a brief delay when processing completes
            if !newValue {
                Task {
                    try? await Task.sleep(for: .seconds(0.5))
                    dismiss()
                }
            }
        }
    }
}

#Preview {
    AddNoteForPeopleView(people: [
        .init(id: UUID(), displayName: "Alex Johnson"),
        .init(id: UUID(), displayName: "Casey Lee")
    ]) { _, _ in }
}

