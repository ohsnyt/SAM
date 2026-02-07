import SwiftUI
import SwiftData

public struct AddNotePresenter: ViewModifier {
    @State private var showing = false
    public let people: [AddNoteForPeopleView.PersonItem]
    public let container: ModelContainer

    public func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Note") { showing = true }
            }
        }
        .sheet(isPresented: $showing) {
            AddNoteForPeopleView(people: people) { text, ids in
                do {
                    let note = try NoteSavingHelper.saveNote(text: text, selectedPeopleIDs: ids, container: container)
                    Task { await InsightGeneratorNotesAdapter.shared.analyzeNote(text: note.text, noteID: note.id) }
                } catch {
                    // TODO: Surface error via DevLogger/alert as appropriate
                }
            }
        }
    }
}

public extension View {
    func addNoteToolbar(people: [AddNoteForPeopleView.PersonItem], container: ModelContainer) -> some View {
        modifier(AddNotePresenter(people: people, container: container))
    }
}
