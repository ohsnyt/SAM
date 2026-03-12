//
//  GuideWindowView.swift
//  SAM
//
//  Help & Training System — Root guide viewer with two-column navigation
//

import SwiftUI

struct GuideWindowView: View {

    @State private var guideService = GuideContentService.shared

    var body: some View {
        NavigationSplitView {
            GuideSidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            if let articleID = guideService.selectedArticleID,
               let article = guideService.article(id: articleID) {
                GuideArticleView(article: article)
            } else {
                welcomePlaceholder
            }
        }
        .navigationTitle("SAM Guide")
    }

    // MARK: - Welcome Placeholder

    private var welcomePlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "book.pages")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("SAM Guide")
                .font(.title2.bold())

            Text("Select a topic from the sidebar to get started.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
