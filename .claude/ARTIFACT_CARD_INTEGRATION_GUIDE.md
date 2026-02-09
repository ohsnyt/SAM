# Integrating AnalysisArtifactCard into InboxDetailView

## Quick Integration Guide

### Where to Add It

The `AnalysisArtifactCard` should appear in the Inbox detail pane, between the evidence header and the link suggestions section.

### Step 1: Find the DetailScrollContent Implementation

Look for a file that contains:
```swift
struct DetailScrollContent: View {
    let item: SamEvidenceItem
    // ...
    var body: some View {
        ScrollView {
            VStack {
                // Evidence header/metadata
                // ...
                
                // ⬅️ INSERT ARTIFACT CARD HERE
                
                // Link suggestions section
                // ...
            }
        }
    }
}
```

### Step 2: Add the Artifact Display

Insert this code where indicated above:

```swift
// Display LLM analysis for note-based evidence
if item.source == .note,
   let noteID = item.sourceUID,
   let noteUUID = UUID(uuidString: noteID) {
    
    // Query the note to get its analysis artifact
    // (We could also query SamAnalysisArtifact directly, but this is cleaner)
    NoteArtifactDisplay(noteID: noteUUID)
}
```

### Step 3: Create the Helper View

Add this helper view at the bottom of InboxDetailView.swift (or in a separate file):

```swift
/// Displays the analysis artifact for a given note
private struct NoteArtifactDisplay: View {
    let noteID: UUID
    
    @Query private var notes: [SamNote]
    @State private var showContactSheet = false
    @State private var selectedPerson: StoredPersonEntity?
    
    init(noteID: UUID) {
        self.noteID = noteID
        // Query for the specific note
        _notes = Query(
            filter: #Predicate<SamNote> { $0.id == noteID },
            sort: \SamNote.createdAt
        )
    }
    
    private var note: SamNote? {
        notes.first { $0.id == noteID }
    }
    
    private var artifact: SamAnalysisArtifact? {
        note?.analysisArtifact
    }
    
    var body: some View {
        if let artifact = artifact {
            AnalysisArtifactCard(artifact: artifact) { person in
                // Handle "Add Contact" button tap
                selectedPerson = person
                showContactSheet = true
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .sheet(isPresented: $showContactSheet) {
                if let person = selectedPerson {
                    CreateContactSheet(person: person)
                }
            }
        }
    }
}

/// Sheet for creating a new contact from an extracted person
private struct CreateContactSheet: View {
    let person: StoredPersonEntity
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Create Contact")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Name: \(person.name)")
                if let relationship = person.relationship {
                    Text("Relationship: \(relationship)")
                        .foregroundStyle(.secondary)
                }
                if !person.aliases.isEmpty {
                    Text("Also known as: \(person.aliases.joined(separator: ", "))")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            Text("This will open the Contacts app to create a new contact with this information.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
                
                Button("Open Contacts") {
                    openContactsApp(for: person)
                    dismiss()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 400)
    }
    
    private func openContactsApp(for person: StoredPersonEntity) {
        #if os(macOS)
        let contactsApp = URL(fileURLWithPath: "/System/Applications/Contacts.app")
        NSWorkspace.shared.open(contactsApp)
        // TODO: Pre-fill contact data if possible
        // This requires more complex CNContactStore integration
        #endif
    }
}
```

## Expected Result

When you view a note-based evidence item in the Inbox:

1. **Header** (existing) - Title, timestamp, participants
2. **Analysis Card** (NEW) - Collapsible sections showing:
   - People extracted (with "NEW" badges and "Add Contact" buttons)
   - Financial topics (with amounts and beneficiaries)
   - Facts, implications, action items
3. **Link Suggestions** (existing) - People/Context linking UI

## Example: Note about Susan

For the note "I just had a daughter. Her name is Susan. I want my young Susie to have a $150,000 life insurance policy."

The card will show:

**People (2)**
- Susan (daughter) [NEW] → [➕ Add Contact]
- Advisor (financial advisor) [NEW] → [➕ Add Contact]

**Financial Topics (1)**
- Life Insurance
  - $150,000
  - For: Susan
  - Sentiment: wants

**Implications (2)**
- Add $150,000 life insurance policy for Susan
- New daughter identified: Susan

Clicking "Add Contact" on Susan will:
1. Show a confirmation sheet with her details
2. Open Contacts.app to create the entry
3. (Future) Pre-fill name and relationship fields

## Alternative: Simpler Integration

If you want a quicker test, just add this directly in your detail view:

```swift
// Quick test - no sheet, just open Contacts
if let artifact = item.note?.analysisArtifact {
    AnalysisArtifactCard(artifact: artifact) { person in
        #if os(macOS)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Contacts.app"))
        #endif
    }
}
```

This will display the card and open Contacts when you click "Add Contact", but won't pre-fill anything yet.
