//
//  TimeCategoryPicker.swift
//  SAM
//
//  Created on February 25, 2026.
//  Phase Q: Time Tracking & Categorization
//
//  Compact Menu-based category picker for calendar event cards.
//  Shows current category as a colored capsule with dropdown override.
//

import SwiftUI

struct TimeCategoryPicker: View {

    let entryID: UUID
    let currentCategory: TimeCategory

    var body: some View {
        Menu {
            ForEach(TimeCategory.allCases, id: \.self) { category in
                Button {
                    try? TimeTrackingRepository.shared.updateCategory(
                        id: entryID,
                        newCategory: category
                    )
                } label: {
                    HStack {
                        Label(category.rawValue, systemImage: category.icon)
                        if category == currentCategory {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: currentCategory.icon)
                    .font(.caption2)
                Text(currentCategory.rawValue)
                    .font(.caption2)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(currentCategory.color.opacity(0.15))
            .foregroundStyle(currentCategory.color)
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
