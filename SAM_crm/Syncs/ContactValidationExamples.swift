//
//  ContactValidationExamples.swift
//  SAM_crm
//
//  Code examples showing different ways to use the contact validation system.
//  These are reference implementations — not meant to be compiled as-is.
//

#if DEBUG

import SwiftUI
import SwiftData

// MARK: - Example 1: Basic List with Auto-Validation

struct Example1_BasicListWithValidation: View {
    @Query private var people: [SamPerson]
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        List(people) { person in
            Text(person.displayName)
        }
        // ✅ This is all you need — validation happens automatically
        .monitorContactChanges(modelContext: modelContext)
    }
}

// MARK: - Example 2: Detail View with Inline Validation

struct Example2_DetailViewWithValidation: View {
    let person: SamPerson
    @Environment(\.modelContext) private var modelContext
    
    @State private var contactIsInvalid = false
    @State private var photo: Image? = nil
    
    var body: some View {
        VStack {
            // Show warning if contact was deleted
            if contactIsInvalid {
                InfoBanner(
                    "This contact was deleted. Would you like to re-link?",
                    action: { showLinkSheet() }
                )
            }
            
            // Rest of your detail view...
        }
        .task(id: person.id) {
            // Validate and fetch photo in one step
            let (isValid, fetchedPhoto) = await validateAndFetchPhoto()
            contactIsInvalid = !isValid
            photo = fetchedPhoto
        }
    }
    
    private func validateAndFetchPhoto() async -> (Bool, Image?) {
        guard let identifier = person.contactIdentifier else {
            return (true, nil)  // Not linked, nothing to validate
        }
        
        // Check if contact still exists
        let isValid = await Task.detached {
            ContactValidator.isValid(identifier)
        }.value
        
        guard isValid else {
            return (false, nil)  // Contact deleted
        }
        
        // Contact is valid, fetch the photo
        // (Use your existing photo fetcher here)
        return (true, nil)
    }
    
    private func showLinkSheet() {
        // Open LinkContactSheet or trigger re-link flow
    }
}

// MARK: - Example 3: Manual Validation for Specific Actions

struct Example3_ManualValidation: View {
    let person: SamPerson
    @Environment(\.modelContext) private var modelContext
    
    @State private var syncManager = ContactsSyncManager()
    @State private var showingError = false
    
    var body: some View {
        VStack {
            Button("Send Message") {
                Task { await sendMessage() }
            }
        }
        .task {
            syncManager.startObserving(modelContext: modelContext)
        }
        .alert("Contact Not Found", isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text("This person's contact was deleted. Please re-link before sending a message.")
        }
    }
    
    private func sendMessage() async {
        // Validate right before the action
        let wasCleared = await syncManager.validatePerson(person)
        
        if wasCleared {
            // Contact was invalid and just got cleared
            showingError = true
            return
        }
        
        guard person.contactIdentifier != nil else {
            // Person was never linked
            showingError = true
            return
        }
        
        // ✅ Contact is valid, proceed with action
        // (Open Messages.app, etc.)
    }
}

// MARK: - Example 4: Batch Validation

struct Example4_BatchValidation: View {
    @Query private var people: [SamPerson]
    @Environment(\.modelContext) private var modelContext
    
    @State private var syncManager = ContactsSyncManager()
    @State private var isValidating = false
    @State private var validationResults: String = ""
    
    var body: some View {
        VStack {
            Text("Linked People: \(linkedCount)")
            
            if isValidating {
                ProgressView("Validating...")
            } else {
                Button("Validate All Contacts") {
                    Task { await validateAll() }
                }
            }
            
            if !validationResults.isEmpty {
                Text(validationResults)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            syncManager.startObserving(modelContext: modelContext)
        }
    }
    
    private var linkedCount: Int {
        people.filter { $0.contactIdentifier != nil }.count
    }
    
    private func validateAll() async {
        isValidating = true
        
        await syncManager.validateAllLinkedContacts()
        
        isValidating = false
        
        let cleared = syncManager.lastClearedCount
        if cleared > 0 {
            validationResults = "Cleared \(cleared) stale link(s)"
        } else {
            validationResults = "All contacts are valid"
        }
    }
}

// MARK: - Example 5: Custom Validation Logic

struct Example5_CustomValidation: View {
    let person: SamPerson
    
    @State private var validationState: ValidationState = .unknown
    
    enum ValidationState {
        case unknown
        case checking
        case valid
        case contactDeleted
        case notInSAMGroup
        case accessDenied
    }
    
    var body: some View {
        VStack {
            switch validationState {
            case .unknown:
                Text("Contact status: Unknown")
            case .checking:
                ProgressView("Checking...")
            case .valid:
                Label("Contact is valid", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .contactDeleted:
                Label("Contact was deleted", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .notInSAMGroup:
                Label("Contact not in SAM group", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .accessDenied:
                Label("Contacts access denied", systemImage: "lock.fill")
                    .foregroundStyle(.red)
            }
            
            Button("Check Contact") {
                Task { await checkContact() }
            }
        }
    }
    
    private func checkContact() async {
        guard let identifier = person.contactIdentifier else {
            validationState = .unknown
            return
        }
        
        validationState = .checking
        
        // Run full validation with detailed results
        let result = await Task.detached {
            ContactValidator.validate(identifier, requireSAMGroup: true)
        }.value
        
        // Map result to UI state
        switch result {
        case .valid:
            validationState = .valid
        case .contactDeleted:
            validationState = .contactDeleted
        case .notInSAMGroup:
            validationState = .notInSAMGroup
        case .accessDenied:
            validationState = .accessDenied
        }
    }
}

// MARK: - Example 6: Settings/Configuration View

struct Example6_ValidationSettings: View {
    @AppStorage("sam.contacts.requireSAMGroup") private var requireSAMGroup = false
    @AppStorage("sam.contacts.validateOnLaunch") private var validateOnLaunch = true
    @AppStorage("sam.contacts.enableDebugLogging") private var enableLogging = false
    
    var body: some View {
        Form {
            Section("Contact Validation") {
                Toggle("Require SAM Group Membership", isOn: $requireSAMGroup)
                    .help("If enabled, contacts must be in the 'SAM' group to stay linked (macOS only)")
                
                Toggle("Validate on App Launch", isOn: $validateOnLaunch)
                    .help("Check all contact links when the app starts")
                
                Toggle("Enable Debug Logging", isOn: $enableLogging)
                    .help("Print validation details to the console")
            }
            
            Section("Info") {
                Text("Contacts are automatically validated when changes are detected in Contacts.app")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Contact Settings")
    }
}

// MARK: - Example 7: Observe Validation State

struct Example7_ObserveValidationState: View {
    @Environment(\.modelContext) private var modelContext
    @State private var syncManager = ContactsSyncManager()
    
    var body: some View {
        VStack {
            if syncManager.isValidating {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Validating contacts...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.regularMaterial, in: Capsule())
            }
            
            if syncManager.lastClearedCount > 0 {
                Text("Recently cleared: \(syncManager.lastClearedCount) link(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            syncManager.startObserving(modelContext: modelContext)
        }
    }
}

// MARK: - Helper Views (for examples)

private struct InfoBanner: View {
    let message: String
    let action: () -> Void
    
    init(_ message: String, action: @escaping () -> Void) {
        self.message = message
        self.action = action
    }
    
    var body: some View {
        HStack {
            Text(message)
            Button("Re-Link", action: action)
        }
        .padding()
        .background(.orange.opacity(0.2))
        .cornerRadius(8)
    }
}

#endif  // DEBUG
