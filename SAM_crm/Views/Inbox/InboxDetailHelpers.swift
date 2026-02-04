import SwiftUI

struct SuggestedLinkRow<ActionsMenu: View>: View {
    let title: String
    let subtitle: String?
    let confidence: Double
    let reason: String
    let systemImage: String

    let status: LinkSuggestionStatus
    let decidedAt: Date?

    let primaryActionTitle: String
    let onPrimary: () -> Void

    @ViewBuilder let actionsMenu: () -> ActionsMenu

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.headline)
                            .lineLimit(1)

                        StatusPill(status: status)
                    }

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let decidedAt, status != .pending {
                        Text("Updated \(format(decidedAt))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Text("Confidence: \(Int((confidence * 100).rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 10)

                VStack(alignment: .trailing, spacing: 8) {
                    actionsMenu()

                    Button(primaryActionTitle) {
                        onPrimary()
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
    }

    private func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
}

struct StatusPill: View {
    let status: LinkSuggestionStatus

    var body: some View {
        Text(status.title)
            .font(.caption2)
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(background)
            )
    }

    private var foreground: Color {
        switch status {
        case .pending: return .secondary
        case .accepted: return .primary
        case .declined: return .secondary
        }
    }

    private var background: Color {
        switch status {
        case .pending: return Color.secondary.opacity(0.12)
        case .accepted: return Color.primary.opacity(0.10)
        case .declined: return Color.orange.opacity(0.14)
        }
    }
}

struct ParticipantRow: View {
    let hint: ParticipantHint
    @Binding var alertMessage: String?
    let onSuggestCreateContact: (String, String, String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: hint.isOrganizer ? "person.crop.circle.fill" : "person.crop.circle")
                .foregroundStyle(hint.isOrganizer ? Color.accentColor : Color.secondary)
            if !hint.isVerified, let email = hint.rawEmail {
                Button(action: { openContactsForEmail(email) }) {
                    nameAndBadges
                }
                .buttonStyle(.plain)
                .help("Open in Contacts to add \(email)")
            } else {
                nameAndBadges
            }
        }
    }

    @ViewBuilder
    private var nameAndBadges: some View {
        Text(hint.displayName)
            .font(.callout)
            .foregroundStyle(hint.isOrganizer ? .primary : .secondary)
        if hint.isOrganizer {
            OrganizerBadge()
        }
        if !hint.isVerified {
            if let email = hint.rawEmail {
                Button(action: {
                    let parts = splitFromDisplayName(hint.displayName)
                    onSuggestCreateContact(parts.first, parts.last, email)
                }) {
                    UnknownBadge()
                }
                .buttonStyle(.plain)
                .help("Add to Contacts")
            } else {
                UnknownBadge()
            }
        }
    }

    private func openContactsForEmail(_ email: String) {
        let contactsApp = URL(fileURLWithPath: "/System/Applications/Contacts.app")
        guard let mailto = URL(string: "mailto:\(email)") else { return }
        do {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open(
                [mailto],
                withApplicationAt: contactsApp,
                configuration: config
            ) { app, error in
                if let error {
                    NSLog("Failed to open Contacts with mailto: %@", error.localizedDescription)
                    alertMessage = "Contacts could not be opened for \(email). You can add it manually in Contacts."
                }
            }
        }
    }
    
    private func splitFromDisplayName(_ display: String) -> (first: String, last: String) {
        let raw: String
        if let angleStart = display.firstIndex(of: "<") {
            raw = String(display[..<angleStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            raw = display
        }
        let comps = raw.split(separator: " ", omittingEmptySubsequences: true)
        if comps.count >= 2 {
            return (String(comps.first!), comps.dropFirst().joined(separator: " "))
        } else {
            return (raw, "")
        }
    }
}

struct OrganizerBadge: View {
    var body: some View {
        Text("Organiser")
            .font(.caption2)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor)
            )
    }
}

struct ToastView: View {
    let message: String
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.tint)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(3)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
        )
        .tint(.yellow)
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 6)
        .accessibilityLabel(Text("Notice: \(message)"))
    }
}

struct ContactPromptView: View {
    let prompt: InboxDetailView.PendingContactPrompt
    let onAdd: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Add to Contacts?")
                    .font(.callout).bold()
                Text(prompt.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add Contact") { onAdd() }
                .buttonStyle(.glass)
            Button("Dismiss") { onDismiss() }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
        )
        .tint(.accentColor)
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 6)
        .accessibilityLabel(Text("Add \(prompt.displayName) to Contacts?"))
    }
}

struct UnknownBadge: View {
    var body: some View {
        Text("Unknown")
            .font(.caption2)
            .foregroundStyle(Color(red: 0.15, green: 0.10, blue: 0.0))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(red: 0.92, green: 0.78, blue: 0.20))
            )
    }
}
