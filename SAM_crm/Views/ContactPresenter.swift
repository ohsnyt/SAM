#if os(macOS)
import SwiftUI
import AppKit
import Contacts
#if canImport(ContactsUI)
import ContactsUI
#endif

@MainActor
final class ContactPresenter: NSObject {
    private let store = CNContactStore()
    private var completionHandler: ((Bool) -> Void)?

    func requestAccessIfNeeded() async -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            do {
                try await store.requestAccess(for: .contacts)
                return CNContactStore.authorizationStatus(for: .contacts) == .authorized
            } catch {
                return false
            }
        default:
            return false
        }
    }

    /// Presents a prefilled new-contact UI as a sheet using an ephemeral NSWindowController.
    func presentNewContact(from anchorView: NSView, firstName: String, lastName: String, email: String?, completion: @escaping (Bool) -> Void) {
        #if canImport(ContactsUI)
        let c = CNMutableContact()
        c.givenName = firstName
        c.familyName = lastName
        if let email, !email.isEmpty {
            c.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: email as NSString)]
        }

        do {
            // Create a vCard for the new contact and open it in Contacts.app on macOS
            let data = try CNContactVCardSerialization.data(with: [c])
            let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let fileURL = tmpDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("vcf")
            try data.write(to: fileURL, options: .atomic)

            self.completionHandler = completion
            let opened = NSWorkspace.shared.open(fileURL)
            self.completionHandler?(opened)
            self.completionHandler = nil
        } catch {
            completion(false)
            self.completionHandler = nil
        }
        #else
        completion(false)
        #endif
    }
}

/// A tiny helper to capture an NSView anchor from SwiftUI so we can present sheets/popovers from AppKit.
struct PopoverAnchorView: NSViewRepresentable {
    @Binding var anchorView: NSView?

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { self.anchorView = v }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif

