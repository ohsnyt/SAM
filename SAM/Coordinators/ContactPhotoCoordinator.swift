//
//  ContactPhotoCoordinator.swift
//  SAM
//
//  Mediates between the contact photo drop/paste UI and ContactPhotoService.
//

import AppKit
import Foundation
import os.log
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ContactPhotoCoordinator")

@MainActor
@Observable
final class ContactPhotoCoordinator {

    static let shared = ContactPhotoCoordinator()

    // MARK: - Published State

    /// Non-nil while an error should be shown inline.
    private(set) var errorMessage: String?

    /// Non-nil while a LinkedIn PDF import success/info message should be shown.
    private(set) var linkedInImportMessage: String?

    /// True while a photo is being processed/saved.
    private(set) var isSaving = false

    /// Safari window IDs opened for photo grabbing; closed after successful drop.
    private(set) var openSafariWindowIDs: [Int] = []

    /// Contact identifiers with a recent photo write — protected from sync overwrite
    /// for a short grace period while Apple Contacts generates the thumbnail.
    private(set) var recentPhotoWrites: [String: Date] = [:]

    // MARK: - Dependencies

    private let photoService = ContactPhotoService.shared

    private init() {}

    // MARK: - Social Profile Browser

    /// Available social profile URLs for a person.
    struct ProfileLinks {
        let linkedIn: URL?
        let facebook: URL?

        var count: Int { (linkedIn != nil ? 1 : 0) + (facebook != nil ? 1 : 0) }
        var isEmpty: Bool { count == 0 }
        var single: URL? { count == 1 ? (linkedIn ?? facebook) : nil }
    }

    /// Extract available profile URLs from a SamPerson, falling back to Apple Contacts social profiles.
    func profileLinks(
        for person: SamPerson,
        contactLinkedInURL: String? = nil,
        contactFacebookURL: String? = nil
    ) -> ProfileLinks {
        // Prefer SAM's stored URL, fall back to Apple Contacts social profile
        let liRaw = person.linkedInProfileURL ?? contactLinkedInURL
        let li = liRaw.flatMap { Self.sanitizeProfileURL($0) }

        let fbRaw = person.facebookProfileURL ?? contactFacebookURL
        var fb = fbRaw.flatMap { Self.sanitizeProfileURL($0) }
        // If this is a confirmed Facebook friend but we have no profile URL,
        // construct a Facebook people search URL from their name.
        if fb == nil, person.facebookFriendedOn != nil {
            let name = (person.displayNameCache ?? person.displayName)
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if !name.isEmpty {
                fb = URL(string: "https://www.facebook.com/search/people/?q=\(name)")
            }
        }
        return ProfileLinks(linkedIn: li, facebook: fb)
    }

    /// Clean up a profile URL string that may have a service prefix (e.g. "linkedin:www.linkedin.com/...")
    /// or be missing a scheme, and return a valid URL.
    private static func sanitizeProfileURL(_ raw: String) -> URL? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip service-name prefix that Apple Contacts sometimes includes
        // e.g. "linkedin:www.linkedin.com/in/jsmith" or "facebook:www.facebook.com/jsmith"
        for prefix in ["linkedin:", "facebook:", "twitter:", "flickr:"] {
            if cleaned.lowercased().hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
                break
            }
        }
        if cleaned.hasPrefix("http") {
            return URL(string: cleaned)
        }
        return URL(string: "https://\(cleaned)")
    }

    /// Open the person's social profile(s) in Safari for photo grabbing.
    /// - Parameter screenOrigin: The screen-coordinate point where the photo view sits,
    ///   used to position the Safari window adjacent to the drop target.
    func openProfileForPhotoGrab(person: SamPerson, photoScreenOrigin: CGPoint? = nil) {
        let links = profileLinks(for: person)
        guard !links.isEmpty else { return }

        closeSafariWindows()

        // Position Safari to the right of the photo area
        let safariOrigin = photoScreenOrigin.map { CGPoint(x: $0.x + 120, y: $0.y) }

        var opened: [Int] = []
        if let li = links.linkedIn, let idx = SafariBrowserHelper.openInNewWindow(url: li, origin: safariOrigin) {
            opened.append(idx)
        }
        if let fb = links.facebook {
            // Stack second window below the first if both exist
            let fbOrigin = safariOrigin.map { CGPoint(x: $0.x, y: $0.y + 40) }
            if let idx = SafariBrowserHelper.openInNewWindow(url: fb, origin: fbOrigin) {
                opened.append(idx)
            }
        }
        openSafariWindowIDs = opened
    }

    /// Open a single URL in Safari for photo grabbing.
    func openURL(url: URL, photoScreenOrigin: CGPoint? = nil) {
        closeSafariWindows()
        let safariOrigin = photoScreenOrigin.map { CGPoint(x: $0.x + 120, y: $0.y) }
        if let idx = SafariBrowserHelper.openInNewWindow(url: url, origin: safariOrigin) {
            openSafariWindowIDs = [idx]
        }
    }

    /// Close any Safari windows opened for photo grabbing.
    func closeSafariWindows() {
        guard !openSafariWindowIDs.isEmpty else { return }
        SafariBrowserHelper.closeWindows(ids: openSafariWindowIDs)
        openSafariWindowIDs = []
    }

    // MARK: - Photo Save

    /// Process raw image data and save to Apple Contacts.
    /// On success, updates the person's `photoThumbnailCache` so the UI refreshes immediately.
    func setPhoto(data: Data, for person: SamPerson) async {
        guard let contactID = person.contactIdentifier else {
            errorMessage = "This person is not linked to an Apple Contact."
            scheduleDismissError()
            return
        }

        isSaving = true
        errorMessage = nil

        guard let jpegData = ImageResizeUtility.processContactPhoto(from: data) else {
            errorMessage = "The image could not be processed. Try a different image."
            isSaving = false
            scheduleDismissError()
            return
        }

        do {
            try await photoService.updatePhoto(identifier: contactID, jpegData: jpegData)
            // Update local cache so SwiftUI refreshes immediately
            person.photoThumbnailCache = jpegData
            // Protect this photo from being overwritten by sync before Apple generates the thumbnail
            recentPhotoWrites[contactID] = Date()
            logger.debug("Photo set for \(person.displayName, privacy: .private)")
            // Close Safari windows that were opened for this grab
            closeSafariWindows()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Photo save failed: \(error.localizedDescription, privacy: .public)")
            scheduleDismissError()
        }

        isSaving = false
    }

    /// Handle dropped NSItemProviders (from `.onDrop`).
    func handleDrop(providers: [NSItemProvider], for person: SamPerson) {
        guard let provider = providers.first else { return }

        // Capture person reference safely for use in @Sendable closures.
        // SamPerson is a SwiftData @Model (non-Sendable) but is only accessed
        // on @MainActor inside Task { @MainActor in }, which is safe.
        nonisolated(unsafe) let personRef = person

        // Try loading image data directly
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                Task { @MainActor in
                    if let data {
                        await self.setPhoto(data: data, for: personRef)
                    } else {
                        self.errorMessage = error?.localizedDescription ?? "Could not read image data."
                        self.scheduleDismissError()
                    }
                }
            }
            return
        }

        // Try loading a URL (e.g., Safari image drag)
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, error in
                Task { @MainActor in
                    guard let url = item as? URL ?? (item as? Data).flatMap({ URL(dataRepresentation: $0, relativeTo: nil) }) else {
                        self.errorMessage = "Could not read the dropped URL."
                        self.scheduleDismissError()
                        return
                    }
                    guard let contactID = personRef.contactIdentifier else {
                        self.errorMessage = "This person is not linked to an Apple Contact."
                        self.scheduleDismissError()
                        return
                    }
                    self.isSaving = true
                    do {
                        let jpegData = try await self.photoService.downloadAndUpdatePhoto(
                            identifier: contactID, url: url
                        )
                        personRef.photoThumbnailCache = jpegData
                        self.closeSafariWindows()
                    } catch {
                        self.errorMessage = error.localizedDescription
                        self.scheduleDismissError()
                    }
                    self.isSaving = false
                }
            }
            return
        }

        errorMessage = "The dropped item is not an image."
        scheduleDismissError()
    }

    /// Handle paste from system clipboard.
    func handlePaste(for person: SamPerson) async {
        let images = ImagePasteUtility.readImagesFromPasteboard()
        guard let (data, _) = images.first else {
            errorMessage = "No image found on the clipboard."
            scheduleDismissError()
            return
        }
        await setPhoto(data: data, for: person)
    }

    /// Returns true if the contact had a photo written recently (within grace period)
    /// and the sync should not overwrite the thumbnail cache.
    static func isPhotoWriteRecent(for contactIdentifier: String, gracePeriod: TimeInterval = 30) -> Bool {
        guard let writeDate = shared.recentPhotoWrites[contactIdentifier] else { return false }
        return Date().timeIntervalSince(writeDate) < gracePeriod
    }

    /// Clear the error message.
    func dismissError() {
        errorMessage = nil
    }

    // MARK: - LinkedIn PDF Import

    /// Process a dropped LinkedIn profile PDF: parse it, create enrichment candidates, and save a note.
    func handleLinkedInPDFDrop(data: Data, for person: SamPerson) async {
        do {
            let profile = try LinkedInPDFParserService.parse(data: data)

            // Build enrichment candidates — skip values that already match existing data
            var candidates: [EnrichmentCandidate] = []

            // Helper: normalize URLs for comparison (strip scheme, trailing slash, lowercase)
            func normalizeURL(_ url: String) -> String {
                url.lowercased()
                    .replacingOccurrences(of: "https://", with: "")
                    .replacingOccurrences(of: "http://", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }

            if let email = profile.email, !email.isEmpty {
                let existingEmail = person.emailCache?.lowercased() ?? ""
                if existingEmail != email.lowercased() {
                    candidates.append(EnrichmentCandidate(
                        personID: person.id,
                        field: .email,
                        proposedValue: email,
                        currentValue: person.emailCache,
                        source: .linkedInProfilePDF,
                        sourceDetail: "LinkedIn Profile PDF"
                    ))
                }
            }

            if let linkedInURL = profile.linkedInURL, !linkedInURL.isEmpty {
                let existingLI = person.linkedInProfileURL ?? ""
                if normalizeURL(existingLI) != normalizeURL(linkedInURL) {
                    candidates.append(EnrichmentCandidate(
                        personID: person.id,
                        field: .linkedInURL,
                        proposedValue: linkedInURL,
                        currentValue: person.linkedInProfileURL,
                        source: .linkedInProfilePDF,
                        sourceDetail: "LinkedIn Profile PDF"
                    ))
                }
            }

            // Fetch current Apple Contact data to avoid proposing identical values
            var existingCompany: String?
            var existingJobTitle: String?
            if let contactID = person.contactIdentifier {
                let contact = await ContactsService.shared.fetchContact(identifier: contactID, keys: .detail)
                existingCompany = contact?.organizationName
                existingJobTitle = contact?.jobTitle
            }

            if let firstPosition = profile.positions.first {
                if !firstPosition.company.isEmpty, firstPosition.company != "Unknown",
                   firstPosition.company.lowercased() != (existingCompany ?? "").lowercased() {
                    candidates.append(EnrichmentCandidate(
                        personID: person.id,
                        field: .company,
                        proposedValue: firstPosition.company,
                        currentValue: existingCompany,
                        source: .linkedInProfilePDF,
                        sourceDetail: "LinkedIn Profile PDF — \(firstPosition.title)"
                    ))
                }
                if !firstPosition.title.isEmpty, firstPosition.title != "Unknown",
                   firstPosition.title.lowercased() != (existingJobTitle ?? "").lowercased() {
                    candidates.append(EnrichmentCandidate(
                        personID: person.id,
                        field: .jobTitle,
                        proposedValue: firstPosition.title,
                        currentValue: existingJobTitle,
                        source: .linkedInProfilePDF,
                        sourceDetail: "LinkedIn Profile PDF — \(firstPosition.company)"
                    ))
                }
            }

            if let phone = profile.phone, !phone.isEmpty {
                candidates.append(EnrichmentCandidate(
                    personID: person.id,
                    field: .phone,
                    proposedValue: phone,
                    currentValue: nil,
                    source: .linkedInProfilePDF,
                    sourceDetail: "LinkedIn Profile PDF"
                ))
            }

            if !candidates.isEmpty {
                try EnrichmentRepository.shared.bulkRecord(candidates)
            }

            // Build a concise note — only new information not already visible in the detail header.
            // Name, headline, and location are already shown in the person view — skip them.
            var noteLines: [String] = []

            if let summary = profile.summary, !summary.isEmpty {
                let trimmed = summary.count > 500 ? String(summary.prefix(500)) + "…" : summary
                noteLines.append(trimmed)
            }

            if let current = profile.positions.first {
                noteLines.append("")
                noteLines.append("Current: \(current.title) at \(current.company)")
            }

            // Highest education only
            if let topEdu = profile.education.first {
                let degree = topEdu.degree ?? ""
                if !degree.isEmpty {
                    noteLines.append("Education: \(degree), \(topEdu.school)")
                } else {
                    noteLines.append("Education: \(topEdu.school)")
                }
            }

            if !profile.topSkills.isEmpty {
                noteLines.append("Skills: \(profile.topSkills.joined(separator: ", "))")
            }

            if !profile.honors.isEmpty {
                noteLines.append("Honors: \(profile.honors.joined(separator: ", "))")
            }

            if !profile.languages.isEmpty {
                noteLines.append("Languages: \(profile.languages.joined(separator: ", "))")
            }

            if let website = profile.websiteURL, !website.isEmpty {
                noteLines.append("Website: \(website)")
            }

            let noteContent = noteLines.joined(separator: "\n")
            let note = try NotesRepository.shared.create(
                content: noteContent,
                sourceType: .typed,
                linkedPeopleIDs: [person.id]
            )

            Task {
                await NoteAnalysisCoordinator.shared.analyzeNote(note)
            }

            let enrichmentCount = candidates.count
            linkedInImportMessage = "Imported LinkedIn profile for \(profile.name). \(enrichmentCount) enrichment candidate\(enrichmentCount == 1 ? "" : "s") queued."
            scheduleDismissLinkedInMessage()

            logger.info("LinkedIn PDF imported for \(person.displayName, privacy: .private): \(enrichmentCount) enrichments, note created")
        } catch {
            errorMessage = "LinkedIn PDF import failed: \(error.localizedDescription)"
            scheduleDismissError()
            logger.error("LinkedIn PDF import failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Dismiss the LinkedIn import message after a delay.
    private func scheduleDismissLinkedInMessage() {
        Task {
            try? await Task.sleep(for: .seconds(5))
            linkedInImportMessage = nil
        }
    }

    // MARK: - Private

    private func scheduleDismissError() {
        Task {
            try? await Task.sleep(for: .seconds(4))
            errorMessage = nil
        }
    }
}
