//
//  PersonDetailView.swift
//  SAM_crm
//
//  Created by David Snyder on 2/1/26.
//

import SwiftUI
#if canImport(Contacts)
import Contacts
#endif

struct PersonDetailView: View {
    let person: PersonDetailModel

    /// Cached contact photo for the current person.  Nil until the async
    /// lookup completes (or if no photo is available).
    @State private var contactPhoto: Image? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                header

                GroupBox("Contexts") {
                    VStack(alignment: .leading, spacing: 8) {
                        if person.contexts.isEmpty {
                            Text("No contexts yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(person.contexts.enumerated()), id: \.offset) { pair in
                                let ctx = pair.element
                                HStack {
                                    Label(ctx.name, systemImage: ctx.icon)
                                    Spacer()
                                    Text(ctx.kindDisplay)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Obligations") {
                    VStack(alignment: .leading, spacing: 10) {
                        if person.consentAlertsCount == 0 && person.responsibilityNotes.isEmpty {
                            Text("No outstanding obligations.")
                                .foregroundStyle(.secondary)
                        } else {
                            if person.consentAlertsCount > 0 {
                                Label("\(person.consentAlertsCount) consent item(s) need review", systemImage: "checkmark.seal")
                            }
                            if !person.responsibilityNotes.isEmpty {
                                ForEach(person.responsibilityNotes, id: \.self) { note in
                                    Label(note, systemImage: "person.badge.shield.checkmark")
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Recent Interactions") {
                    VStack(alignment: .leading, spacing: 8) {
                        if person.recentInteractions.isEmpty {
                            Text("No recent interactions recorded.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(person.recentInteractions.enumerated()), id: \.offset) { pair in
                                let i = pair.element
                                HStack(alignment: .top) {
                                    Image(systemName: i.icon)
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(i.title)
                                        Text(i.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(i.whenText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("SAM Insights") {
                    VStack(alignment: .leading, spacing: 12) {
                        if person.insights.isEmpty {
                            Text("No insights for this person right now.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(person.insights.enumerated()), id: \.offset) { pair in
                                InsightCardView(insight: pair.element)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: 760, alignment: .topLeading)
        }
        .navigationTitle(person.displayName)
        // Fetch the photo once when the view appears, and again if the
        // selected person changes (e.g. navigating between rows).
        .task(id: person.id) {
            contactPhoto = await ContactPhotoFetcher.thumbnail(for: person)
        }
    }

    // MARK: - Header with watermark photo

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            // Left: name, badges, action buttons.
            VStack(alignment: .leading, spacing: 6) {
                Text(person.displayName)
                    .font(.title2)
                    .bold()

                if !person.roleBadges.isEmpty {
                    Text(person.roleBadges.joined(separator: " • "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button("Open in Contacts") { /* later */ }
                    Button("Message") { /* later */ }
                    Button("Schedule") { /* later */ }
                }
                .buttonStyle(.glass)
                .padding(.top, 4)
            }

            Spacer()

            // Right: contact photo, pinned to the top-right corner.
            if let photo = contactPhoto {
                photo
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
//                    .blur(radius: 1)
                    .opacity(0.65)
                    .mask(
                        // Fade the bottom and left edges so it dissolves
                        // gently rather than sitting as a hard shape.
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0.4),
                                .init(color: .black.opacity(0.6), location: 0.7),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .topTrailing,
                            endPoint: .bottomLeading
                        )
                    )
            }
        }
    }
}

// MARK: - Contact Photo Fetcher

/// Stateless, nonisolated helper that pulls a thumbnail from CNContactStore.
/// All work is synchronous CNContactStore I/O so it runs on a background
/// executor via the `async` wrapper.  Nothing here touches the main actor.
enum ContactPhotoFetcher {

    /// Returns a SwiftUI `Image` backed by the contact's thumbnail, or `nil`
    /// if no photo is available or Contacts access hasn't been granted.
    ///
    /// Resolution order:
    ///   1. Direct identifier lookup  (`contactIdentifier`)  — O(1), no predicate.
    ///   2. Email predicate lookup    (`email`)              — one predicate query.
    ///   3. nil.
    static func thumbnail(for person: PersonDetailModel) async -> Image? {
        // Guard: we need at least one lookup key.
        guard person.contactIdentifier != nil || person.email != nil else { return nil }

        // Move the synchronous CNContactStore I/O off the main actor.
        return await Task.detached(priority: .userInitiated) {
            await fetchThumbnailSync(
                contactIdentifier: person.contactIdentifier,
                email: person.email
            )
        }.value
    }

    // MARK: - Private

    private static func fetchThumbnailSync(contactIdentifier: String?, email: String?) -> Image? {
        #if canImport(Contacts)
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }

        let store = CNContactStore()

        // 1. Try direct identifier hit first (fastest path).
        if let identifier = contactIdentifier {
            if let image = imageFromContact(store: store, identifier: identifier) {
                return image
            }
        }

        // 2. Fall back to email-predicate lookup.
        if let email = email {
            let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
            guard let contact = try? store.unifiedContacts(
                matching: predicate,
                keysToFetch: [CNContactThumbnailImageDataKey as CNKeyDescriptor]
            ).first else { return nil }

            if let data = contact.thumbnailImageData {
                #if os(macOS)
                guard let nsImage = NSImage(data: data) else { return nil }
                return Image(nsImage: nsImage)
                #else
                guard let uiImage = UIImage(data: data) else { return nil }
                return Image(uiImage: uiImage)
                #endif
            }
        }

        return nil
        #else
        return nil
        #endif
    }

    /// Fetches the thumbnail from a single CNContact by its stable identifier.
    private static func imageFromContact(store: CNContactStore, identifier: String) -> Image? {
        #if canImport(Contacts)
        guard let contact = try? store.unifiedContact(
            withIdentifier: identifier,
            keysToFetch: [CNContactThumbnailImageDataKey as CNKeyDescriptor]
        ) else { return nil }

        guard let data = contact.thumbnailImageData else { return nil }

        #if os(macOS)
        guard let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
        #else
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #endif
        #else
        return nil
        #endif
    }
}
