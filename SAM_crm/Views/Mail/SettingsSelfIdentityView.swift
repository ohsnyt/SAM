import SwiftUI
import Contacts
import Combine

public class SelfIdentitySettings: ObservableObject {
    @Published var selfEmails: [String] = []
    
    func refreshFromContacts(using store: CNContactStore) throws {
        let keysToFetch = [CNContactEmailAddressesKey as CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        var foundEmails: Set<String> = []
        try store.enumerateContacts(with: request) { contact, _ in
            for email in contact.emailAddresses {
                foundEmails.insert(email.value as String)
            }
        }
        DispatchQueue.main.async {
            self.selfEmails = Array(foundEmails).sorted()
        }
    }
}

public struct SettingsSelfIdentityView: View {
    @StateObject private var settings = SelfIdentitySettings()
    private let store: CNContactStore?
    
    @State private var newEmail: String = ""
    
    public init(store: CNContactStore? = nil) {
        self.store = store
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Self Identity")
                .font(.headline)
            
            Text("Identify your own email addresses so SAM can classify you correctly.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            if settings.selfEmails.isEmpty {
                Text("No self email addresses added.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(settings.selfEmails, id: \.self) { email in
                    HStack {
                        Text(email)
                            .lineLimit(1)
                        Spacer()
                        Button(action: {
                            if let index = settings.selfEmails.firstIndex(of: email) {
                                settings.selfEmails.remove(at: index)
                            }
                        }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                }
            }
            
            HStack {
                TextField("Add new email", text: $newEmail)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .disableAutocorrection(true)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                
                Button("Add") {
                    let normalized = newEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !normalized.isEmpty,
                          normalized.contains("@"),
                          !settings.selfEmails.contains(normalized)
                    else { return }
                    
                    settings.selfEmails.append(normalized)
                    settings.selfEmails.sort()
                    newEmail = ""
                }
                .disabled(newEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            
            if store != nil {
                Button("Refresh from Contacts") {
                    if let store {
                        try? settings.refreshFromContacts(using: store)
                    }
                }
            }
        }
        .padding()
    }
}

#Preview {
    SettingsSelfIdentityView()
}
