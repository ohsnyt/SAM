//
//  FieldContactLookupService.swift
//  SAM Field
//
//  Looks up CNContact thumbnail images by name or email on iOS.
//  Used to show contact photos in the recording participant list.
//

import Foundation
import Contacts
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAMField", category: "FieldContactLookup")

actor FieldContactLookupService {

    static let shared = FieldContactLookupService()
    private init() {}

    private let store = CNContactStore()

    // MARK: - Authorization

    var isAuthorized: Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestAccess(for: .contacts)
            logger.info("Contacts access \(granted ? "granted" : "denied")")
            return granted
        } catch {
            logger.error("Contacts access request failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Thumbnail Lookup

    /// Returns the thumbnail image data for the first CNContact that matches
    /// the given email (preferred) or display name (fallback).
    func thumbnail(forEmail email: String?, name: String) async -> Data? {
        guard isAuthorized else { return nil }

        // Try email match first (more reliable)
        if let email, !email.isEmpty, let data = await thumbnailByEmail(email) {
            return data
        }
        // Fall back to name match
        return await thumbnailByName(name)
    }

    private func thumbnailByEmail(_ email: String) async -> Data? {
        let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
        let keys: [CNKeyDescriptor] = [CNContactThumbnailImageDataKey as CNKeyDescriptor]
        do {
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
            return contacts.first?.thumbnailImageData
        } catch {
            logger.debug("Contact email lookup failed for \(email, privacy: .private): \(error.localizedDescription)")
            return nil
        }
    }

    private func thumbnailByName(_ name: String) async -> Data? {
        let predicate = CNContact.predicateForContacts(matchingName: name)
        let keys: [CNKeyDescriptor] = [CNContactThumbnailImageDataKey as CNKeyDescriptor]
        do {
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
            return contacts.first?.thumbnailImageData
        } catch {
            logger.debug("Contact name lookup failed for \(name, privacy: .private): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Batch Lookup

    /// Returns thumbnail data for each (name, email?) pair, in the same order.
    func thumbnails(for attendees: [(name: String, email: String?)]) async -> [Data?] {
        var results: [Data?] = []
        for attendee in attendees {
            let data = await thumbnail(forEmail: attendee.email, name: attendee.name)
            results.append(data)
        }
        return results
    }
}
