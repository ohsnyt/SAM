//
//  ContactsSyncView.swift
//  SAM_crm
//
//  UI for manually syncing contacts from Contacts.app into SAM.
//  Uses the new ContactsImporter with deduplication.
//

import SwiftUI
import SwiftData

struct ContactsSyncView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @State private var isSyncing = false
    @State private var lastSyncResult: SyncResult?
    @State private var errorMessage: String?
    
    struct SyncResult {
        let imported: Int
        let updated: Int
        let timestamp: Date
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Sync Contacts")
                    .font(.title2)
                    .bold()
                
                Text("Import contacts from the SAM group in Contacts.app. Existing people will be linked (no duplicates created).")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            
            Divider()
            
            // Last sync info
            if let result = lastSyncResult {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Last Sync", systemImage: "clock")
                            .font(.headline)
                        
                        Text(result.timestamp, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Divider()
                        
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(result.imported)")
                                    .font(.title3)
                                    .bold()
                                Text("New")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                            
                            VStack(alignment: .leading) {
                                Text("\(result.updated)")
                                    .font(.title3)
                                    .bold()
                                Text("Linked")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            
            // Error message
            if let error = errorMessage {
                GroupBox {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.callout)
                    }
                }
                .backgroundStyle(.orange.opacity(0.1))
            }
            
            Spacer()
            
            // Action buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button {
                    Task { await syncNow() }
                } label: {
                    if isSyncing {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Syncing...")
                        }
                    } else {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(isSyncing)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
    
    private func syncNow() async {
        isSyncing = true
        errorMessage = nil
        
        defer { isSyncing = false }
        
        do {
            let importer = ContactsImporter(modelContext: modelContext)
            let result = try await importer.importFromSAMGroup()
            
            lastSyncResult = SyncResult(
                imported: result.imported,
                updated: result.updated,
                timestamp: Date()
            )
            
            // Auto-dismiss after successful sync
            try? await Task.sleep(for: .seconds(1.5))
            dismiss()
            
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    ContactsSyncView()
        .modelContainer(for: [SamPerson.self], inMemory: true)
}
