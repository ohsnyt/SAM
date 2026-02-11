//
//  ContactsTestView.swift
//  SAM
//
//  Created on February 9, 2026.
//  Phase B: Test view to verify ContactsService works
//

import SwiftUI
import AppKit

struct ContactsTestView: View {
    @State private var contacts: [ContactDTO] = []
    @State private var groups: [ContactGroupDTO] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var authStatus: String = "Unknown"
    
    var body: some View {
        NavigationStack {
            List {
                Section("Authorization") {
                    HStack {
                        Text("Status:")
                        Spacer()
                        Text(authStatus)
                            .foregroundStyle(.secondary)
                    }
                    
                    Button("Request Access") {
                        Task {
                            await requestAccess()
                        }
                    }
                }
                
                Section("Groups") {
                    if groups.isEmpty {
                        Text("No groups loaded")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(groups) { group in
                            HStack {
                                Image(systemName: "folder")
                                Text(group.name)
                                Spacer()
                                Button("Load") {
                                    Task {
                                        await loadContactsFromGroup(group.name)
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    
                    Button("Fetch Groups") {
                        Task {
                            await fetchGroups()
                        }
                    }
                }
                
                Section("Contacts (\(contacts.count))") {
                    if isLoading {
                        ProgressView("Loading...")
                    } else if contacts.isEmpty {
                        Text("No contacts loaded")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(contacts) { contact in
                            ContactRowView(contact: contact)
                        }
                    }
                    
                    Button("Load All Contacts") {
                        Task {
                            await loadAllContacts()
                        }
                    }
                }
                
                if let errorMessage = errorMessage {
                    Section("Error") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Contacts Service Test")
            .task {
                await checkAuthStatus()
            }
        }
    }
    
    // MARK: - Actions
    
    private func checkAuthStatus() async {
        let status = await ContactsService.shared.authorizationStatus()
        authStatus = statusString(for: status)
    }
    
    private func requestAccess() async {
        let granted = await ContactsService.shared.requestAccess()
        authStatus = granted ? "Authorized" : "Denied"
        
        if granted {
            await fetchGroups()
        }
    }
    
    private func fetchGroups() async {
        isLoading = true
        errorMessage = nil
        
        groups = await ContactsService.shared.fetchGroups()
        
        isLoading = false
    }
    
    private func loadAllContacts() async {
        isLoading = true
        errorMessage = nil
        
        contacts = await ContactsService.shared.fetchContacts(keys: .minimal)
        
        isLoading = false
    }
    
    private func loadContactsFromGroup(_ groupName: String) async {
        isLoading = true
        errorMessage = nil
        
        contacts = await ContactsService.shared.fetchContacts(
            inGroupNamed: groupName,
            keys: .minimal
        )
        
        isLoading = false
    }
    
    private func statusString(for status: CNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Authorized"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Determined"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - Contact Row

struct ContactRowView: View {
    let contact: ContactDTO
    
    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            if let imageData = contact.thumbnailImageData,
               let nsImage = NSImage(data: imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.blue.gradient)
                    .frame(width: 40, height: 40)
                    .overlay {
                        Text(contact.initials)
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
            }
            
            // Name and details
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName)
                    .font(.headline)
                
                if !contact.organizationName.isEmpty {
                    Text(contact.organizationName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                if !contact.phoneNumbers.isEmpty {
                    Text(contact.phoneNumbers[0].number)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview {
    ContactsTestView()
}

// MARK: - Import Missing

import Contacts
