import SwiftUI
import Foundation

public struct AddNoteView: View {
    @State private var text: String = ""
    public var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    public init(onSave: @escaping (String) -> Void) {
        self.onSave = onSave
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Note").font(.title2).bold()
            Text("Paste or dictate a brief note. SAM will analyze it to surface insights.")
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onSave(trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 420)
    }
}

#Preview {
    AddNoteView { _ in }
}
