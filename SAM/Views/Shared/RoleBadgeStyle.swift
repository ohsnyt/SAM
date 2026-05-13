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

    /// Built-in roles ship with these defaults. Custom roles (user-defined via
    /// `RoleDefinition.colorHex`) override these when present; unknown names
    /// without a custom color fall through to gray.
    @MainActor
    static func forBadge(_ badge: String) -> RoleBadgeStyle {
        if let customHex = customColorCache[badge], let color = Color(hex: customHex) {
            return RoleBadgeStyle(color: color, icon: iconForBuiltIn(badge) ?? "tag.circle.fill")
        }
        return builtInStyle(for: badge)
    }

    /// Built-in default style. Exposed for the editor legend so it can render
    /// known roles without depending on the runtime cache.
    static func builtInStyle(for badge: String) -> RoleBadgeStyle {
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

    private static func iconForBuiltIn(_ badge: String) -> String? {
        let style = builtInStyle(for: badge)
        return style.color == .gray && style.icon == "tag.circle.fill" ? nil : style.icon
    }

    /// Names of built-in roles (in legend display order).
    static let builtInRoleNames: [String] = [
        "Client", "Applicant", "Lead", "Prospect",
        "Agent", "External Agent", "Referral Partner", "Vendor"
    ]

    // MARK: - Custom Role Cache

    /// In-memory cache of custom role name → colorHex. Populated lazily and
    /// invalidated whenever a `RoleDefinition` is saved or deleted.
    @MainActor
    private static var customColorCache: [String: String] = [:]

    /// Reload the cache from the active RoleDefinitions. Call after role
    /// edits so the next render picks up new colors.
    @MainActor
    static func refreshCustomCache() {
        guard let roles = try? RoleRecruitingRepository.shared.fetchAllRoles() else { return }
        var map: [String: String] = [:]
        for role in roles {
            if let hex = role.colorHex, !hex.isEmpty {
                map[role.name] = hex
            }
        }
        customColorCache = map
    }
}

// MARK: - Color Hex Helpers

extension Color {
    /// Parses "#RRGGBB" / "RRGGBB" / "#RRGGBBAA". Returns nil for malformed input.
    init?(hex: String) {
        var trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6 || trimmed.count == 8,
              let value = UInt64(trimmed, radix: 16) else { return nil }
        let r, g, b, a: Double
        if trimmed.count == 6 {
            r = Double((value >> 16) & 0xFF) / 255.0
            g = Double((value >>  8) & 0xFF) / 255.0
            b = Double( value        & 0xFF) / 255.0
            a = 1.0
        } else {
            r = Double((value >> 24) & 0xFF) / 255.0
            g = Double((value >> 16) & 0xFF) / 255.0
            b = Double((value >>  8) & 0xFF) / 255.0
            a = Double( value        & 0xFF) / 255.0
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Returns "#RRGGBB" from this Color (best effort; macOS only).
    var hexString: String? {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
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
                    .samFont(.caption2)
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
