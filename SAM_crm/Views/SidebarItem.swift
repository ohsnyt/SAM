//
//  SidebarItem.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case awareness = "Awareness"
    case people = "People"
    case contexts = "Contexts"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .awareness: return "sparkles"
        case .people: return "person.2"
        case .contexts: return "square.3.layers.3d"
        }
    }
}
