//
//  GuideArticleView.swift
//  SAM
//
//  Help & Training System — Single article view with scrollable content
//

import SwiftUI

struct GuideArticleView: View {

    let article: GuideArticle
    @State private var guideService = GuideContentService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Article title
                Text(article.title)
                    .font(.title.bold())
                    .textSelection(.enabled)

                // Section breadcrumb
                if let section = guideService.sections.first(where: { $0.id == article.sectionID }) {
                    HStack(spacing: 4) {
                        Image(systemName: section.icon)
                            .font(.caption)
                        Text(section.title)
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }

                Divider()

                // Rendered markdown body
                GuideMarkdownRenderer(
                    markdown: guideService.markdownBody(for: article),
                    sectionID: article.sectionID
                )
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }
}
