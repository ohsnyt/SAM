//
//  ContactValidationDebugView.swift
//  SAM_crm
//
//  Temporary debugging view to diagnose contact validation issues.
//  Add this to your app to see what's happening with contact validation.
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
                
                // System Info
                GroupBox("System Status") {
                    Text(diagnosisOutput.isEmpty ? "Tap 'Run Diagnostics' to check" : diagnosisOutput)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
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
                        runDiagnostics()
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
    
    private func runDiagnostics() {
        diagnosisOutput = ContactValidator.diagnose()
    }
    
    private func testAllContacts() async {
        isRunning = true
        defer { isRunning = false }
        
        let toTest = linkedPeople.map { (person: $0.displayName, id: $0.contactIdentifier!) }
        
        let results = await Task.detached {
            toTest.map { item -> (String, Bool) in
                let valid = ContactValidator.isValid(item.id)
                return ("\(item.person) (\(item.id))", valid)
            }
        }.value
        
        await MainActor.run {
            testResults = results
        }
    }
}

#Preview {
    ContactValidationDebugView()
        .modelContainer(for: [SamPerson.self], inMemory: true)
}

#endif
