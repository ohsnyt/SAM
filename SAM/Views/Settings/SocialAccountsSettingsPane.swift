//
//  SocialAccountsSettingsPane.swift
//  SAM
//
//  Settings pane that aggregates per-platform social account management
//  (LinkedIn, Facebook, Substack). Each platform appears as a DisclosureGroup
//  with its existing *ImportSettingsContent view, including connect /
//  re-analyze / disconnect actions.
//

import SwiftUI

struct SocialAccountsSettingsPane: View {

    @State private var linkedInExpanded: Bool = true
    @State private var facebookExpanded: Bool = false
    @State private var substackExpanded: Bool = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Connect, re-analyze, or disconnect the social accounts SAM uses for coaching. Disconnecting clears the cached profile and Grow analysis for that platform but preserves imported contacts, messages, and interaction history.")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    DisclosureGroup(isExpanded: $linkedInExpanded) {
                        LinkedInImportSettingsContent()
                            .padding(.top, 8)
                    } label: {
                        platformLabel(
                            title: "LinkedIn",
                            symbol: "person.crop.rectangle.stack",
                            color: .blue
                        )
                    }

                    Divider()

                    DisclosureGroup(isExpanded: $facebookExpanded) {
                        FacebookImportSettingsContent()
                            .padding(.top, 8)
                    } label: {
                        platformLabel(
                            title: "Facebook",
                            symbol: "f.square.fill",
                            color: .indigo
                        )
                    }

                    Divider()

                    DisclosureGroup(isExpanded: $substackExpanded) {
                        SubstackImportSettingsContent()
                            .padding(.top, 8)
                    } label: {
                        platformLabel(
                            title: "Substack",
                            symbol: "newspaper.fill",
                            color: .orange
                        )
                    }
                }
                .padding()
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func platformLabel(title: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 20)
            Text(title)
                .samFont(.headline)
        }
    }
}
