//
//  ContextsPlaceholderView.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI

struct ContextsPlaceholderView: View {
    var body: some View {
        ContentUnavailableView("Contexts",
                               systemImage: "square.3.layers.3d",
                               description: Text("This view will show households, businesses, and recruiting contexts."))
            .padding()
    }
}
