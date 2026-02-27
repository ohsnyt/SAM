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
    @State private var strategic = StrategicCoordinator.shared
    @State private var selectedTab = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Segmented picker
                Picker("Pipeline", selection: $selectedTab) {
                    Text("Client Pipeline").tag(0)
                    Text("Recruiting").tag(1)
                    Text("Production").tag(2)
                    Text("Strategic").tag(3)
                    Text("Goals").tag(4)
                }
                .pickerStyle(.segmented)
                .padding()

                Divider()

                switch selectedTab {
                case 0:
                    ClientPipelineDashboardView(tracker: tracker)
                case 2:
                    ProductionDashboardView(tracker: tracker)
                case 3:
                    StrategicInsightsView(coordinator: strategic)
                case 4:
                    GoalProgressView()
                default:
                    RecruitingPipelineDashboardView(tracker: tracker)
                }

                // Relationship Map preview
                GraphMiniPreviewView()
                    .padding()
            }
        }
        .navigationTitle("Pipeline")
        .toolbar {
            ToolbarItem {
                Button {
                    tracker.refresh()
                    if selectedTab == 3 {
                        Task { await strategic.generateDigest(type: .onDemand) }
                        ScenarioProjectionEngine.shared.refresh()
                    }
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
