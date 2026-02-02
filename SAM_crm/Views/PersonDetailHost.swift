//
//  PersonDetailHost.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI

struct PersonDetailHost: View {
    let selectedPersonID: UUID?

    var body: some View {
        if let id = selectedPersonID,
           let person = MockPeopleStore.byID[id] {
            PersonDetailView(person: person)
        } else {
            ContentUnavailableView("Select a person",
                                   systemImage: "person.crop.circle",
                                   description: Text("Choose someone from the People list."))
            .padding()
        }
    }
}
