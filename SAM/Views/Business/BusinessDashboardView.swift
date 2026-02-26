//
//  BusinessDashboardView.swift
//  SAM
//
//  Created on February 25, 2026.
//  Phase R: Pipeline Intelligence
//
//  Container view with segmented picker for Client and Recruiting pipelines.
//

import SwiftUI

struct BusinessDashboardView: View {

    @State private var tracker = PipelineTracker.shared
    @State private var selectedTab = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Segmented picker
                Picker("Pipeline", selection: $selectedTab) {
                    Text("Client Pipeline").tag(0)
                    Text("Recruiting").tag(1)
                    Text("Production").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()

                Divider()

                switch selectedTab {
                case 0:
                    ClientPipelineDashboardView(tracker: tracker)
                case 2:
                    ProductionDashboardView(tracker: tracker)
                default:
                    RecruitingPipelineDashboardView(tracker: tracker)
                }
            }
        }
        .navigationTitle("Pipeline")
        .toolbar {
            ToolbarItem {
                Button {
                    tracker.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh pipeline metrics")
            }
        }
        .onAppear {
            tracker.refresh()
        }
    }
}
