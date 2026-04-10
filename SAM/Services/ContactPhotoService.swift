//
//  ContactPhotoService.swift
//  SAM
//
//  Actor that writes processed photo data to Apple Contacts via CNContactStore.
//

import Contacts
import Foundation
import os.log

actor ContactPhotoService {

    static let shared = ContactPhotoService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ContactPhotoService")

    private let store = CNContactStore()

    private init() {}

    /// Write processed JPEG image data to the contact identified by `identifier`.
    /// Returns `true` on success.
    func updatePhoto(identifier: String, jpegData: Data) throws {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized else {
            throw ContactPhotoError.notAuthorized
        }

        let keys: [CNKeyDescriptor] = [CNContactImageDataKey as CNKeyDescriptor]
        let contact = try store.unifiedContact(withIdentifier: identifier, keysToFetch: keys)
        let mutable = contact.mutableCopy() as! CNMutableContact
        mutable.imageData = jpegData

        let saveRequest = CNSaveRequest()
        saveRequest.update(mutable)
        try store.execute(saveRequest)

        logger.debug("Photo updated for contact \(identifier, privacy: .private)")
    }

    /// Download image from a URL, process it, and write to the contact.
    /// Returns the processed JPEG data on success for local cache update.
    func downloadAndUpdatePhoto(identifier: String, url: URL) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: url)
        #if canImport(AppKit)
        guard let jpegData = ImageResizeUtility.processContactPhoto(from: data) else {
            throw ContactPhotoError.invalidImage
        }
        try updatePhoto(identifier: identifier, jpegData: jpegData)
        return jpegData
        #else
        throw ContactPhotoError.invalidImage
        #endif
    }
}

enum ContactPhotoError: LocalizedError {
    case notAuthorized
    case invalidImage
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "Contacts access not authorized. Check System Settings > Privacy > Contacts."
        case .invalidImage:
            "The image could not be read. Try a different image."
        case .saveFailed(let detail):
            "Failed to save photo: \(detail)"
        }
    }
}
