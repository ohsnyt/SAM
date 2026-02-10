# Next: Integrate Contacts-Rich UI into PersonDetailView

**Current Status:** Services and UI components created, ready for integration  
**Next Task:** Wire up the new sections into existing PersonDetailView

---

## 📍 What We Have

### ✅ Complete
1. **ContactSyncService.swift** — Fetch/write/cache CNContact data
2. **PersonDetailSections.swift** — UI components (Family, ContactInfo, Professional, Summary)
3. **SAMModels.swift** — Updated with cache fields (migration: SAM_v5 → SAM_v6)
4. **context.md** — Architecture documented

### 🔍 Need to Find
- **PersonDetailView.swift** — Current implementation
- **PersonDetailHost.swift** — Parent view (if exists)
- **SAMApp.swift** — App initialization (to configure ContactSyncService)

---

## 🎯 Integration Steps

### Step 1: Find PersonDetailView

Search for:
- `struct PersonDetailView`
- `@Query private var person: [SamPerson]`
- Current sections (Insights, Contexts, etc.)

### Step 2: Add CNContact Fetch

```swift
struct PersonDetailView: View {
    let person: SamPerson
    
    @State private var contact: CNContact?
    @State private var isLoadingContact = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Existing header
                
                // NEW: Contact-rich sections (if contact loaded)
                if let contact {
                    FamilySection(contact: contact, person: person)
                    ContactInfoSection(contact: contact)
                    ProfessionalSection(contact: contact)
                    SummaryNoteSection(contact: contact, person: person)
                } else if isLoadingContact {
                    ProgressView("Loading contact info...")
                } else if person.contactIdentifier != nil {
                    // Contact not found - show "Unlinked" state
                    UnlinkedContactBanner(person: person)
                }
                
                // Existing sections (Insights, Contexts, etc.)
            }
        }
        .task {
            await loadContact()
        }
    }
    
    private func loadContact() async {
        isLoadingContact = true
        defer { isLoadingContact = false }
        
        do {
            contact = try ContactSyncService.shared.contact(for: person)
        } catch {
            print("⚠️ Failed to load contact: \(error)")
        }
    }
}
```

### Step 3: Add Unlinked Badge Handler

```swift
struct UnlinkedContactBanner: View {
    let person: SamPerson
    
    @Environment(\.modelContext) private var modelContext
    @State private var showingOptions = false
    
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            
            VStack(alignment: .leading) {
                Text("Contact Not Found")
                    .font(.headline)
                Text("This person's contact was deleted or moved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button("Options") {
                showingOptions = true
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.orange.opacity(0.1))
        .cornerRadius(8)
        .confirmationDialog("Contact Not Found", isPresented: $showingOptions) {
            Button("Archive") {
                person.isArchived = true
                try? modelContext.save()
            }
            
            Button("Resync") {
                Task {
                    // Attempt to find contact by cached name/email
                    try? await ContactSyncService.shared.refreshCache(for: person)
                }
            }
            
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This contact no longer exists in Contacts.app. You can archive it, attempt to resync, or keep it as-is.")
        }
    }
}
```

### Step 4: Configure Service in App Init

Find `SAMApp.swift` or equivalent:

```swift
@main
struct SAMApp: App {
    // Existing...
    
    init() {
        // Existing initialization...
        
        // Configure ContactSyncService
        ContactSyncService.shared.configure(
            modelContext: SAMModelContainer.shared.mainContext
        )
        
        // Initial cache refresh (background, low priority)
        Task(priority: .low) {
            try? await ContactSyncService.shared.refreshAllCaches()
        }
    }
    
    // ...
}
```

---

## 🎯 Update AnalysisArtifactCard Action

Find `InboxDetailSections.swift` → `NoteArtifactDisplay`:

### Current Code
```swift
AnalysisArtifactCard(artifact: artifact) { person in
    // Parse name into first/last
    let components = person.name.split(separator: " ", maxSplits: 1)
    let firstName = components.first.map(String.init) ?? person.name
    let lastName = components.count > 1 ? String(components[1]) : ""
    
    onSuggestCreateContact(firstName, lastName, "")
}
```

### Updated Code
```swift
AnalysisArtifactCard(artifact: artifact) { person in
    // Detect if person is a dependent
    if isDependent(person.relationship),
       let parent = item.linkedPeople.first {
        // Add to parent's family in Contacts
        Task {
            do {
                try ContactSyncService.shared.addChild(
                    name: person.name,
                    relationship: person.relationship,
                    to: parent
                )
                
                // Show success banner
                showSuccessBanner("Added \(person.name) to \(parent.displayNameCache ?? "contact")'s family")
            } catch {
                showErrorBanner("Failed to add family member: \(error.localizedDescription)")
            }
        }
    } else {
        // Fallback: Create separate contact
        let components = person.name.split(separator: " ", maxSplits: 1)
        let firstName = components.first.map(String.init) ?? person.name
        let lastName = components.count > 1 ? String(components[1]) : ""
        onSuggestCreateContact(firstName, lastName, "")
    }
}

private func isDependent(_ relationship: String?) -> Bool {
    guard let rel = relationship?.lowercased() else { return false }
    return rel.contains("son") || 
           rel.contains("daughter") || 
           rel.contains("child") ||
           rel.contains("dependent")
}

private func showSuccessBanner(_ message: String) {
    // TODO: Implement banner notification
    print("✅ \(message)")
}

private func showErrorBanner(_ message: String) {
    // TODO: Implement banner notification
    print("❌ \(message)")
}
```

---

## 🧪 Testing Checklist

### Test 1: View Person with Contact
1. Launch app
2. Navigate to People list
3. Select person with `contactIdentifier`
4. **Verify:**
   - Family section displays spouse/children from CNContact
   - Contact Info section displays phone/email/address
   - Professional section displays company/title
   - Summary section displays CNContact.note

### Test 2: Add Child to Family
1. Create note: "I have a son William"
2. View note in Inbox
3. Click "Add to Harvey's Family" button
4. **Verify:**
   - Success banner appears
   - Open Contacts.app → Harvey's contact
   - William appears in "Related Names" section
5. Navigate back to Harvey in SAM
6. **Verify:**
   - William now appears in FamilySection

### Test 3: AI Summary Generation
1. Open person detail
2. Click "Suggest AI Update" in SummaryNoteSection
3. **Verify:**
   - Approval sheet opens with generated draft
   - Text is editable
4. Edit text → Click "Add to Contacts"
5. Open Contacts.app → person's contact
6. **Verify:**
   - Note field updated with new summary
   - Separator (`---`) between old and new notes

### Test 4: Orphaned Contact Handling
1. Delete Harvey's contact in Contacts.app
2. Navigate to Harvey in SAM
3. **Verify:**
   - "Unlinked" banner appears
   - Options: Archive / Resync / Cancel
4. Click "Archive"
5. **Verify:**
   - Harvey removed from People list
   - Evidence/Insights still exist

---

## 🚧 Known Issues to Address

### 1. Concurrent Cache Refresh
**Problem:** Multiple views might trigger cache refresh simultaneously  
**Solution:** Debounce refresh operations, use single background queue

### 2. Large Contact Lists
**Problem:** Bulk refresh on launch might be slow with 5000+ contacts  
**Solution:** Refresh only active people (not archived), paginate refresh

### 3. Name Formatting Edge Cases
**Problem:** `CNContactFormatter.string(from:style:)` might return nil  
**Solution:** Fallback to manual concatenation: `"\(givenName) \(familyName)"`

### 4. Write Conflicts
**Problem:** User edits contact in Contacts.app while SAM writes  
**Solution:** Use CNChangeHistoryFetchRequest to detect conflicts, retry or alert

---

## 📝 Questions for User

1. **Should family section appear above or below existing sections?**
   - Option A: Top (family is identity-core)
   - Option B: After Insights (insights are action-focused)

2. **Should we auto-expand sections or start collapsed?**
   - Option A: All expanded (maximize visibility)
   - Option B: Collapsed by default (reduce scroll)

3. **What to do if CNContact has >10 children?**
   - Option A: Show all (might be long)
   - Option B: Show first 5 + "Show more" button

4. **Should "Add to Family" button require confirmation?**
   - Option A: Direct action (fast)
   - Option B: Confirmation dialog (safer)

---

## 🎯 Success Metrics

**Integration Complete When:**
- [ ] PersonDetailView displays CNContact data
- [ ] "Add to Family" writes to Contacts successfully
- [ ] AI summary approval flow works
- [ ] Orphaned contact badge appears when contact deleted
- [ ] Cache refresh improves list performance
- [ ] No crashes or permission dialogs

**User Experience Win:**
```
User opens Harvey's detail in SAM:

Before:
- Name: Harvey Snodgrass
- Email: harvey@example.com
- Recent Interactions: [list]
- Insights: [list]

After:
- Photo, Name, Role badges
- Family: Sarah (spouse), William (son), Emily (daughter)
- Contact: 555-1234 (mobile), harvey@example.com
- Professional: VP Engineering, Acme Corp
- Summary: "Client since 2020. Married with two children..."
- Recent Interactions: [list]
- Insights: [list]

Result: Rich, actionable identity data with zero manual entry.
```

---

**Next Session:** Find PersonDetailView and integrate sections 🔧
