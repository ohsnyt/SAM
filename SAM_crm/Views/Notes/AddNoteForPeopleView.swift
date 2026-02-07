import SwiftUI

public struct AddNoteForPeopleView: View {
    public struct PersonItem: Identifiable, Hashable {
        public let id: UUID
        public let displayName: String
    }
    @State private var text: String = ""
    @State private var selected: Set<UUID> = []
    public let people: [PersonItem]
    public var onSave: (_ text: String, _ selectedPeopleIDs: [UUID]) -> Void
    @Environment(\.dismiss) private var dismiss

    public init(people: [PersonItem], onSave: @escaping (_ text: String, _ selectedPeopleIDs: [UUID]) -> Void) {
        self.people = people
        self.onSave = onSave
        // Pre-select all provided people when sheet opens
        self._selected = State(initialValue: Set(people.map { $0.id }))
    }

    public var body: some View {
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
                Button("Save") {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onSave(trimmed, Array(selected))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 640)
    }
}

#Preview {
    AddNoteForPeopleView(people: [
        .init(id: UUID(), displayName: "Alex Johnson"),
        .init(id: UUID(), displayName: "Casey Lee")
    ]) { _, _ in }
}
