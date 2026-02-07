import Contacts
import Foundation

/// Represents the "Me" contact information retrieved from the user's macOS Contacts.
public struct MeContactInfo {
    /// The full name of the "Me" contact, if available.
    public let fullName: String?
    /// A list of unique, normalized email addresses associated with the "Me" contact.
    public let emails: [String]
}

/// Errors that can occur when fetching the "Me" contact.
public enum MeContactError: Error {
    /// The app is not authorized to access the user's contacts.
    case unauthorized
    /// The "Me" contact is not configured or available on the device.
    case notAvailable
}

/// Manages retrieval of the macOS user's "Me" contact information.
///
/// Usage:
/// - The host app must handle requesting and verifying authorization to access contacts.
/// - This manager fetches the "Me" contact and extracts emails and the full name.
/// - Throws an error if authorization is missing or the "Me" contact is unavailable.
public final class MeIdentityManager {
    private let store: CNContactStore

    /// Initializes the manager with a contact store.
    /// - Parameter store: The CNContactStore instance to use for fetching contacts.
    public init(store: CNContactStore) {
        self.store = store
    }

    /// Fetches the "Me" contact from the contact store.
    ///
    /// - Throws: `MeContactError.unauthorized` if contact access is not authorized.
    ///           `MeContactError.notAvailable` if the "Me" contact is not configured.
    /// - Returns: `MeContactInfo` containing full name and emails of the "Me" contact.
    public func fetchMeContact() throws -> MeContactInfo {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            throw MeContactError.unauthorized
        }

        guard let meId = store.meContactIdentifier, !meId.isEmpty else {
            throw MeContactError.notAvailable
        }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]

        let contact = try store.unifiedContact(withIdentifier: meId, keysToFetch: keys)

        let formatter = PersonNameComponentsFormatter()
        var nameComponents = PersonNameComponents()
        nameComponents.givenName = contact.givenName
        nameComponents.middleName = contact.middleName
        nameComponents.familyName = contact.familyName

        let fullName = formatter.string(from: nameComponents).isEmpty
            ? nil
            : formatter.string(from: nameComponents)

        let emails = MeIdentityManager.normalizeEmails(
            contact.emailAddresses.map { $0.value as String }
        )

        return MeContactInfo(fullName: fullName, emails: emails)
    }

    /// Normalizes an array of email addresses by trimming whitespace,
    /// converting to lowercase, and removing duplicates.
    /// - Parameter emails: The array of email strings to normalize.
    /// - Returns: A new array with unique, normalized email addresses.
    public static func normalizeEmails(_ emails: [String]) -> [String] {
        emails
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .uniqued()
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
