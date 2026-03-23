//
//  LinkInsertionPopover.swift
//  SAM
//
//  Created on March 23, 2026.
//  Popover for inserting hyperlinks or QR codes into invitation drafts.
//  Shows preset event URLs, user's website, and a freeform URL field.
//

import SwiftUI

struct LinkInsertionPopover: View {

    let event: SamEvent
    let editorHandle: RichInvitationEditorHandle
    @Binding var isPresented: Bool

    @State private var selectedPreset: PresetLink?
    @State private var customURL = ""
    @State private var displayText = ""
    @State private var insertAsQR = false

    private var presetLinks: [PresetLink] {
        var links: [PresetLink] = []

        if let joinLink = event.joinLink, !joinLink.isEmpty {
            links.append(PresetLink(label: "Event Join Link", url: joinLink))
        }

        let profile = BusinessProfileService.shared.profile()
        if !profile.website.isEmpty {
            links.append(PresetLink(label: "Your Website", url: profile.website))
        }

        return links
    }

    private var resolvedURL: String {
        if let preset = selectedPreset {
            return preset.url
        }
        return customURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resolvedDisplayText: String {
        let text = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        if let preset = selectedPreset { return preset.label }
        return resolvedURL
    }

    private var canInsert: Bool {
        !resolvedURL.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Insert Link")
                .samFont(.headline)

            // Preset links
            if !presetLinks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quick Links")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(presetLinks, id: \.url) { preset in
                        HStack(spacing: 6) {
                            Image(systemName: selectedPreset?.url == preset.url ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedPreset?.url == preset.url ? .blue : .secondary)
                                .samFont(.body)

                            VStack(alignment: .leading) {
                                Text(preset.label)
                                    .samFont(.body)
                                Text(preset.url)
                                    .samFont(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedPreset?.url == preset.url {
                                selectedPreset = nil
                            } else {
                                selectedPreset = preset
                                customURL = ""
                            }
                        }
                    }
                }
            }

            Divider()

            // Custom URL
            VStack(alignment: .leading, spacing: 4) {
                Text("Custom URL")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)

                TextField("https://…", text: $customURL)
                    .textFieldStyle(.roundedBorder)
                    .samFont(.body)
                    .onChange(of: customURL) { _, newValue in
                        if !newValue.isEmpty {
                            selectedPreset = nil
                        }
                    }
            }

            // Display text
            VStack(alignment: .leading, spacing: 4) {
                Text("Display Text")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)

                TextField("Link text (optional)", text: $displayText)
                    .textFieldStyle(.roundedBorder)
                    .samFont(.body)
            }

            // QR code option
            Toggle("Insert as QR code image", isOn: $insertAsQR)
                .samFont(.body)

            Divider()

            // Actions
            HStack {
                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.escape)

                Button(insertAsQR ? "Insert QR Code" : "Insert Link") {
                    insertContent()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canInsert)
                .keyboardShortcut(.return)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func insertContent() {
        let urlString = resolvedURL

        if insertAsQR {
            editorHandle.insertQRCode(from: urlString)
        } else if let url = URL(string: urlString) {
            editorHandle.insertLink(url: url, displayText: resolvedDisplayText)
        }

        isPresented = false
    }
}

// MARK: - Preset Link

private struct PresetLink: Equatable {
    let label: String
    let url: String
}
