//
//  SettingsView.swift
//  SAM_crm
//
//  Created by Assistant on 2/9/26.
//  Clean rebuild - Phase A: Foundation
//
//  Placeholder for settings - will be fully implemented in Phase I
//

import SwiftUI

struct SettingsView: View {
    
    @State private var selectedTab: SettingsTab = .general
    
    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case permissions = "Permissions"
        case calendar = "Calendar"
        case contacts = "Contacts"
        case development = "Development"
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .permissions: return "lock.shield"
            case .calendar: return "calendar"
            case .contacts: return "person.crop.circle"
            case .development: return "hammer"
            }
        }
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                tabContent(for: tab)
                    .tabItem {
                        Label(tab.rawValue, systemImage: tab.icon)
                    }
                    .tag(tab)
            }
        }
        .frame(width: 600, height: 400)
    }
    
    @ViewBuilder
    private func tabContent(for tab: SettingsTab) -> some View {
        VStack(spacing: 20) {
            Image(systemName: tab.icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            
            Text(tab.rawValue)
                .font(.title2)
            
            Text("Coming in Phase I")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    SettingsView()
}
