//
//  RoleBadgeStyle.swift
//  SAM
//
//  Created on February 20, 2026.
//
//  Consistent role badge styling (color + icon) used across list rows and detail views.
//

import SwiftUI

struct RoleBadgeStyle {
    let color: Color
    let icon: String

    /// Known role → style mapping. Every role gets a unique color + icon.
    static func forBadge(_ badge: String) -> RoleBadgeStyle {
        switch badge {
        case "Client":
            return RoleBadgeStyle(color: .green, icon: "c.circle.fill")
        case "Applicant":
            return RoleBadgeStyle(color: .yellow, icon: "clock.circle.fill")
        case "Lead":
            return RoleBadgeStyle(color: .orange, icon: "star.circle.fill")
        case "Prospect":
            return RoleBadgeStyle(color: .mint, icon: "p.circle.fill")
        case "Vendor":
            return RoleBadgeStyle(color: .purple, icon: "v.circle.fill")
        case "Agent":
            return RoleBadgeStyle(color: .teal, icon: "a.circle.fill")
        case "External Agent":
            return RoleBadgeStyle(color: .indigo, icon: "e.circle.fill")
        case "Referral Partner":
            return RoleBadgeStyle(color: .pink, icon: "r.circle.fill")
        default:
            return RoleBadgeStyle(color: .gray, icon: "tag.circle.fill")
        }
    }
}

/// A compact role badge icon with a fast-appearing tooltip on hover.
struct RoleBadgeIconView: View {
    let badge: String

    @State private var showTooltip = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        let style = RoleBadgeStyle.forBadge(badge)
        Image(systemName: style.icon)
            .font(.system(size: 14))
            .foregroundStyle(style.color)
            .popover(isPresented: $showTooltip, arrowEdge: .bottom) {
                Text(badge)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
            .onHover { hovering in
                hoverTask?.cancel()
                if hovering {
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeIn(duration: 0.12)) {
                            showTooltip = true
                        }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.1)) {
                        showTooltip = false
                    }
                }
            }
    }
}
