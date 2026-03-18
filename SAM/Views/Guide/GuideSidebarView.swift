//
//  GuideSidebarView.swift
//  SAM
//
//  Help & Training System — Section list with disclosure groups and search
//

import SwiftUI

struct GuideSidebarView: View {

    @State private var guideService = GuideContentService.shared
    @State private var searchText = ""
    @State private var expandedSections: Set<String> = []

    var body: some View {
        List(selection: $guideService.selectedArticleID) {
            if searchText.isEmpty {
                sectionsList
            } else {
                searchResults
            }
        }
        .searchable(text: $searchText, prompt: "Search guides")
        .listStyle(.sidebar)
        .onChange(of: guideService.selectedSectionID) { _, newSection in
            if let newSection {
                expandedSections.insert(newSection)
            }
        }
        .onAppear {
            // Expand the initially selected section
            if let sectionID = guideService.selectedSectionID {
                expandedSections.insert(sectionID)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var sectionsList: some View {
        ForEach(guideService.sections) { section in
            Section(isExpanded: sectionBinding(for: section.id)) {
                ForEach(guideService.articles(inSection: section.id)) { article in
                    NavigationLink(value: article.id) {
                        Text(article.title)
                            .samFont(.callout)
                    }
                }
            } header: {
                Label(section.title, systemImage: section.icon)
                    .samFont(.headline)
            }
        }
    }

    private func sectionBinding(for sectionID: String) -> Binding<Bool> {
        Binding(
            get: { expandedSections.contains(sectionID) },
            set: { isExpanded in
                if isExpanded {
                    expandedSections.insert(sectionID)
                } else {
                    expandedSections.remove(sectionID)
                }
            }
        )
    }

    // MARK: - Search Results

    @ViewBuilder
    private var searchResults: some View {
        let results = guideService.search(query: searchText)
        if results.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            ForEach(results) { article in
                NavigationLink(value: article.id) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(article.title)
                            .samFont(.callout)
                        if let section = guideService.sections.first(where: { $0.id == article.sectionID }) {
                            Text(section.title)
                                .samFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
