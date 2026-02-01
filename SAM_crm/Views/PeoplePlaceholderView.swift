//
//  PeoplePlaceholderView.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI

struct PeoplePlaceholderView: View {
    var body: some View {
        ContentUnavailableView("People",
                               systemImage: "person.2",
                               description: Text("This view will show your contacts and relationship health."))
            .padding()
    }
}
