//
//  PeopleFilter.swift
//  SAM_crm
//
//  Created by David Snyder on 2/1/26.
//

enum PeopleFilter: String, CaseIterable, Identifiable {
    case all
    case clients
    case prospects
    case partners
    case vendors
    case recruits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .clients: return "Clients"
        case .prospects: return "Prospects"
        case .partners: return "Partners"
        case .vendors: return "Vendors"
        case .recruits: return "Recruits"
        }
    }
}
