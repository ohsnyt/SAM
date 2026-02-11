//
//  ContactValidationDebugView.swift
//  SAM_crm
//
//  Debugging view to diagnose contact validation issues.
//  Updated to use ContactsService (Phase B architecture)
//

#if DEBUG

import SwiftUI
import SwiftData
import Contacts

struct ContactValidationDebugView: View {
    @Query private var people: [SamPerson]
    @Environment(\.modelContext) private var modelContext
    
    @State private var diagnosisOutput: String = ""
    @State private var testResults: [(String, Bool)] = []
    @State private var isRunning = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                
                // Header
                Text("Contact Validation Diagnostics")
                    .font(.title)
                    .bold()
                
                Text("Phase B: Using ContactsService")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                // System Info
                GroupBox("System Status") {
                    VStack(alignment: .leading, spacing: 8) {
                        if diagnosisOutput.isEmpty {
                            Text("Tap 'Run Diagnostics' to check authorization status")
                                .foregroundStyle(.secondary)
                        } else {
                            Text(diagnosisOutput)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
                
                // Test All Contacts
                GroupBox("Linked Contacts Test") {
                    VStack(alignment: .leading, spacing: 10) {
                        if linkedPeople.isEmpty {
                            Text("No linked contacts found")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(linkedPeople.count) linked people in SAM")
                                .font(.headline)
                            
                            if testResults.isEmpty {
                                Text("Tap 'Test All Contacts' to validate")
                                    .foregroundStyle(.secondary)
                            } else {
                                Divider()
                                ForEach(Array(testResults.enumerated()), id: \.offset) { index, result in
                                    HStack {
                                        Image(systemName: result.1 ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            .foregroundStyle(result.1 ? .green : .red)
                                        Text(result.0)
                                            .font(.system(.caption, design: .monospaced))
                                        Spacer()
                                        Text(result.1 ? "Valid" : "Invalid")
                                            .font(.caption)
                                            .foregroundStyle(result.1 ? .green : .red)
                                    }
                                }
                            }
                        }
                    }
                }
                
                // Actions
                HStack {
                    Button("Run Diagnostics") {
                        Task { await runDiagnostics() }
                    }
                    .disabled(isRunning)
                    
                    Button("Test All Contacts") {
                        Task { await testAllContacts() }
                    }
                    .disabled(isRunning || linkedPeople.isEmpty)
                    
                    Button("Clear Results") {
                        diagnosisOutput = ""
                        testResults = []
                    }
                }
                
                if isRunning {
                    ProgressView("Testing contacts...")
                }
                
                // Raw Data
                GroupBox("Raw Data") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Total people: \(people.count)")
                        Text("Linked people: \(linkedPeople.count)")
                        Text("Unlinked people: \(people.count - linkedPeople.count)")
                        
                        Divider()
                        
                        Text("Sample Contact Identifiers:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        ForEach(linkedPeople.prefix(5)) { person in
                            Text("\(person.displayName): \(person.contactIdentifier ?? "nil")")
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding()
        }
    }
    
    private var linkedPeople: [SamPerson] {
        people.filter { $0.contactIdentifier != nil }
    }
    
    /// Run diagnostics using ContactsService
    private func runDiagnostics() async {
        isRunning = true
        defer { isRunning = false }
        
        // Check authorization status
        let status = await ContactsService.shared.authorizationStatus()
        
        var output = "Contacts Authorization Status: "
        switch status {
        case .authorized:
            output += "✅ Authorized\n\n"
            
            // Fetch groups to confirm access works
            let groups = await ContactsService.shared.fetchGroups()
            output += "Available Groups (\(groups.count)):\n"
            for group in groups.prefix(10) {
                output += "  • \(group.name)\n"
            }
            
            if groups.count > 10 {
                output += "  ... and \(groups.count - 10) more\n"
            }
            
        case .denied:
            output += "❌ Denied\n"
            output += "Please grant access in System Settings → Privacy & Security → Contacts"
        case .restricted:
            output += "⚠️ Restricted\n"
            output += "Contacts access is restricted by device policy"
        case .notDetermined:
            output += "❓ Not Determined\n"
            output += "App has not requested permission yet"
        case .limited:
            output += "⚠️ Limited\n"
            output += "Only limited contacts are accessible"
        @unknown default:
            output += "❔ Unknown (\(status.rawValue))"
        }
        
        diagnosisOutput = output
    }
    
    /// Test all linked contacts using ContactsService
    private func testAllContacts() async {
        isRunning = true
        defer { isRunning = false }
        
        let toTest = linkedPeople.map { 
            (person: $0.displayName, id: $0.contactIdentifier!) 
        }
        
        var results: [(String, Bool)] = []
        
        // Validate each contact using ContactsService
        for item in toTest {
            let isValid = await ContactsService.shared.isValidContact(identifier: item.id)
            results.append(("\(item.person) (\(item.id))", isValid))
        }
        
        testResults = results
    }
}

#Preview {
    ContactValidationDebugView()
        .modelContainer(for: [SamPerson.self], inMemory: true)
}

#endif
