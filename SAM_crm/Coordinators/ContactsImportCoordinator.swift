import Foundation
import Contacts
import SwiftUI

@MainActor
final class ContactsImportCoordinator {

    static let shared = ContactsImportCoordinator()

    private let peopleRepo = PeopleRepository.shared
    private let permissions = PermissionsManager.shared

    // Settings
    @AppStorage("sam.contacts.enabled") private var importEnabled: Bool = true
    @AppStorage("sam.contacts.selectedGroupIdentifier") private var selectedGroupIdentifier: String = ""
    @AppStorage("sam.contacts.import.lastRunAt") private var lastRunAt: Double = 0

    private var debounceTask: Task<Void, Never>?

    // Contacts change sync can be relatively fast; periodic triggers can be conservative.
    private let minimumIntervalNormal: TimeInterval = 300   // 5 minutes
    private let minimumIntervalChanged: TimeInterval = 10   // 10 seconds

    func kick(reason: String) {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await importIfNeeded(reason: reason)
        }
    }

    func importNow() async {
        await importContacts()
    }

    private func importIfNeeded(reason: String) async {
        guard importEnabled else { return }
        guard !selectedGroupIdentifier.isEmpty else { return }

        let now = Date().timeIntervalSince1970
        let isPeriodicTrigger = reason == "app launch" || reason == "app became active"
        let minInterval = isPeriodicTrigger ? minimumIntervalNormal : minimumIntervalChanged
        let elapsed = now - lastRunAt
        guard elapsed > minInterval else { return }

        await importContacts()
    }

    private func importContacts() async {

        // Check permissions WITHOUT requesting (no dialogs from background tasks)
        guard permissions.hasContactsAccess else { return }

        let contactStore = permissions.contactStore

        // Resolve the selected group
        let groups: [CNGroup]
        do {
            groups = try contactStore.groups(matching: nil)
        } catch {
            return
        }
        guard let group = groups.first(where: { $0.identifier == selectedGroupIdentifier }) else {
            return
        }

        // Fetch contacts in group
        let predicate = CNContact.predicateForContactsInGroup(withIdentifier: group.identifier)
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]
        let contacts: [CNContact]
        do {
            contacts = try contactStore.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
        } catch {
            return
        }

        var upserted = 0
        for c in contacts {
            let fullName = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let email = c.emailAddresses.first.map { String($0.value) }
            do {
                try peopleRepo.upsertFromContacts(contactIdentifier: c.identifier,
                                                  displayName: fullName.isEmpty ? "Unnamed" : fullName,
                                                  email: email)
                upserted += 1
            } catch {
            }
        }

        lastRunAt = Date().timeIntervalSince1970
    }
}
