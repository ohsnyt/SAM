//
//  SearchResultRow.swift
//  SAM
//
//  Created by Assistant on 2/26/26.
//  Advanced Search — lightweight row views for search results.
//

import SwiftUI

// MARK: - Person Row

struct SearchPersonRow: View {
    let person: SamPerson

    var body: some View {
        HStack(spacing: 8) {
            if let photoData = person.photoThumbnailCache,
               let nsImage = NSImage(data: photoData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 24, height: 24)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(person.displayNameCache ?? person.displayName)
                        .font(.body)
                        .lineLimit(1)

                    ForEach(person.roleBadges, id: \.self) { badge in
                        RoleBadgeIconView(badge: badge)
                    }
                }

                if let email = person.emailCache ?? person.email {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text("Person")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.12))
                .clipShape(Capsule())
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Context Row

struct SearchContextRow: View {
    let context: SamContext

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: context.kind.icon)
                .frame(width: 24, height: 24)
                .foregroundStyle(context.kind.color)

            VStack(alignment: .leading, spacing: 1) {
                Text(context.name)
                    .font(.body)
                    .lineLimit(1)

                Text(context.kind.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("Context")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.12))
                .clipShape(Capsule())
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Note Row

struct SearchNoteRow: View {
    let note: SamNote

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "note.text")
                .frame(width: 24, height: 24)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text(note.summary ?? String(note.content.prefix(100)))
                    .font(.body)
                    .lineLimit(2)

                Text(note.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("Note")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.12))
                .clipShape(Capsule())
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Evidence Row

struct SearchEvidenceRow: View {
    let item: SamEvidenceItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: sourceIcon)
                .frame(width: 24, height: 24)
                .foregroundStyle(sourceColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(1)

                Text(item.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(item.occurredAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var sourceIcon: String {
        switch item.source {
        case .calendar: return "calendar"
        case .mail: return "envelope"
        case .iMessage: return "message"
        case .phoneCall: return "phone"
        case .faceTime: return "video"
        case .contacts: return "person.crop.circle"
        case .note: return "note.text"
        case .manual: return "square.and.pencil"
        }
    }

    private var sourceColor: Color {
        switch item.source {
        case .calendar: return .red
        case .mail: return .blue
        case .iMessage: return .teal
        case .phoneCall: return .green
        case .faceTime: return .mint
        case .contacts: return .green
        case .note: return .orange
        case .manual: return .purple
        }
    }
}

// MARK: - Insight Row

struct SearchInsightRow: View {
    let insight: SamInsight

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb.fill")
                .frame(width: 24, height: 24)
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 1) {
                Text(insight.title)
                    .font(.body)
                    .lineLimit(1)

                if let person = insight.samPerson {
                    Text(person.displayNameCache ?? person.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(insight.urgency.displayText)
                .font(.caption2)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(urgencyColor)
                .clipShape(Capsule())
        }
        .padding(.vertical, 2)
    }

    private var urgencyColor: Color {
        switch insight.urgency {
        case .low: return .gray
        case .medium: return .orange
        case .high: return .red
        }
    }
}

// MARK: - Outcome Row

struct SearchOutcomeRow: View {
    let outcome: SamOutcome

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(outcome.outcomeKind.themeColor)
                .frame(width: 10, height: 10)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(outcome.title)
                    .font(.body)
                    .lineLimit(1)

                if let person = outcome.linkedPerson {
                    Text(person.displayNameCache ?? person.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(outcome.outcomeKind.displayName)
                .font(.caption2)
                .foregroundStyle(outcome.outcomeKind.themeColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(outcome.outcomeKind.themeColor.opacity(0.12))
                .clipShape(Capsule())
        }
        .padding(.vertical, 2)
    }
}
