//
//  PipelineDashboardView.swift
//  SAM
//
//  Created on March 4, 2026.
//  Phase 3: Sidebar Reorganization
//
//  Wrapper view with Client / Recruiting sub-segmented control,
//  consolidating the two pipeline tabs into one.
//

import SwiftUI

struct PipelineDashboardView: View {

    @Bindable var tracker: PipelineTracker

    @State private var selectedTab = 0  // 0 = Client, 1 = Recruiting

    var body: some View {
        VStack(spacing: 0) {
            Picker("Pipeline", selection: $selectedTab) {
                Text("Client").tag(0)
                Text("Recruiting").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            switch selectedTab {
            case 0:
                ClientPipelineDashboardView(tracker: tracker)
            case 1:
                RecruitingPipelineDashboardView(tracker: tracker)
            default:
                EmptyView()
            }
        }
    }
}
