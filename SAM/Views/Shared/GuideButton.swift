//
//  GuideButton.swift
//  SAM
//
//  Help & Training System — Reusable contextual help button
//

import SwiftUI

/// A small "?" button that opens the SAM Guide to a specific article.
/// Placed in toolbars and section headers throughout the app.
struct GuideButton: View {

    let articleID: String

    @AppStorage("sam.guide.showHelpButtons") private var showHelpButtons: Bool = true

    var body: some View {
        if showHelpButtons {
            Button {
                GuideContentService.shared.navigateTo(articleID: articleID)
            } label: {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open guide")
        }
    }
}
