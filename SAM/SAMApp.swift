//
//  SAMApp.swift
//  SAM_crm
//
//  Created by Assistant on 2/9/26.
//  Clean rebuild - Phase A: Foundation
//

import SwiftUI
import SwiftData

@main
struct SAMApp: App {
    
    // MARK: - Lifecycle
    
    init() {
        print("🚀 [SAMApp] Initializing...")
        
        // Configure repositories with shared container
        // Must happen before any data access
        configureDataLayer()
        
        print("✅ [SAMApp] Ready")
    }
    
    // MARK: - Scene
    
    var body: some Scene {
        WindowGroup {
            AppShellView()
                .modelContainer(SAMModelContainer.shared)
                .task {
                    // Initial setup on first launch
                    await performInitialSetup()
                }
        }
        .commands {
            // TODO: Add app commands (Phase I)
        }
        
        #if os(macOS)
        Settings {
            SettingsView()
                .modelContainer(SAMModelContainer.shared)
        }
        #endif
    }
    
    // MARK: - Configuration
    
    private func configureDataLayer() {
        // Wire repositories to the shared container
        // This ensures all SwiftData operations hit the same store
        PeopleRepository.shared.configure(container: SAMModelContainer.shared)
        EvidenceRepository.shared.configure(container: SAMModelContainer.shared)
        
        print("📊 [SAMApp] Data layer configured with container: \(Unmanaged.passUnretained(SAMModelContainer.shared).toOpaque())")
    }
    
    private func performInitialSetup() async {
        print("🔧 [SAMApp] Performing initial setup...")
        
        // Seed data on first launch (if needed)
        #if DEBUG
        // TODO Phase A: Re-enable if you have FixtureSeeder
        // await FixtureSeeder.seedIfNeeded(using: SAMModelContainer.shared)
        #endif
        
        // TODO Phase B: Initialize services
        // TODO Phase C: Kick import coordinators
        // TODO Phase H: Generate insights
        
        print("✅ [SAMApp] Initial setup complete")
    }
}
