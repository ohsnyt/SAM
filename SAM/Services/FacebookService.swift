//
//  FacebookService.swift
//  SAM
//
//  Phase FB-1: Facebook Data Export Parsing Service
//
//  Actor-based service that parses Facebook JSON data export files.
//  All JSON parsing happens off the main thread. String fields are
//  repaired for Facebook's mojibake encoding (Latin-1 encoded UTF-8).
//
//  Mirrors LinkedInService.swift architecture.
//

import Foundation
import os.log

// MARK: - FacebookService

actor FacebookService {

    static let shared = FacebookService()
    private init() {}

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "FacebookService")

    // MARK: - Public Parsing API

    /// Parse the friend roster from `connections/friends/your_friends.json`.
    func parseFriends(in folder: URL) async -> [FacebookFriendDTO] {
        let url = folder.appending(path: "connections/friends/your_friends.json")
        guard let data = try? Data(contentsOf: url) else {
            logger.debug("No friends file found at \(url.path)")
            return []
        }

        do {
            let wrapper = try JSONDecoder().decode(FBFriendsWrapper.self, from: data)
            return wrapper.friends_v2.map { raw in
                FacebookFriendDTO(
                    name: repairFacebookUTF8(raw.name),
                    friendedOn: Date(timeIntervalSince1970: TimeInterval(raw.timestamp))
                )
            }
        } catch {
            logger.error("Failed to parse friends JSON: \(error)")
            return []
        }
    }

    /// Parse the user's own profile from `personal_information/profile_information/profile_information.json`.
    func parseUserProfile(in folder: URL) async -> UserFacebookProfileDTO? {
        let url = folder.appending(path: "personal_information/profile_information/profile_information.json")
        guard let data = try? Data(contentsOf: url) else {
            logger.debug("No profile_information file found at \(url.path)")
            return nil
        }

        do {
            let wrapper = try JSONDecoder().decode(FBProfileWrapper.self, from: data)
            let p = wrapper.profile_v2
            return UserFacebookProfileDTO(
                fullName: repairFacebookUTF8(p.name.full_name),
                firstName: repairFacebookUTF8(p.name.first_name),
                lastName: repairFacebookUTF8(p.name.last_name),
                currentCity: p.current_city.map { repairFacebookUTF8($0.name) },
                hometown: p.hometown.map { repairFacebookUTF8($0.name) },
                birthday: p.birthday.map { .init(year: $0.year, month: $0.month, day: $0.day) },
                relationship: p.relationship.map {
                    .init(
                        status: repairFacebookUTF8($0.status),
                        partner: $0.partner.map { repairFacebookUTF8($0) }
                    )
                },
                familyMembers: (p.family_members ?? []).map {
                    .init(name: repairFacebookUTF8($0.name), relation: repairFacebookUTF8($0.relation))
                },
                workExperiences: (p.work_experiences ?? []).map {
                    .init(
                        employer: repairFacebookUTF8($0.employer),
                        title: $0.title.map { repairFacebookUTF8($0) },
                        location: $0.location.map { repairFacebookUTF8($0) }
                    )
                },
                educationExperiences: (p.education_experiences ?? []).map {
                    .init(
                        name: repairFacebookUTF8($0.name),
                        schoolType: $0.school_type.map { repairFacebookUTF8($0) },
                        concentrations: ($0.concentrations ?? []).map { repairFacebookUTF8($0) }
                    )
                },
                websites: (p.websites ?? []).map { $0.address },
                profileUri: p.profile_uri
            )
        } catch {
            logger.error("Failed to parse profile_information JSON: \(error)")
            return nil
        }
    }

    /// Recursively parse all Messenger threads across inbox/, e2ee_cutover/, and archived_threads/.
    /// Returns individual message records with thread metadata.
    func parseMessengerThreads(in folder: URL) async -> [FacebookMessageDTO] {
        let messageCategories: [(subpath: String, category: FacebookMessageCategory)] = [
            ("your_facebook_activity/messages/inbox", .inbox),
            ("your_facebook_activity/messages/e2ee_cutover", .e2ee),
            ("your_facebook_activity/messages/archived_threads", .archived),
            ("your_facebook_activity/messages/filtered_threads", .filtered),
        ]

        var allMessages: [FacebookMessageDTO] = []

        for (subpath, category) in messageCategories {
            let dir = folder.appending(path: subpath)
            guard let threadDirs = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for threadDir in threadDirs {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: threadDir.path, isDirectory: &isDir),
                      isDir.boolValue else { continue }

                let messageFile = threadDir.appending(path: "message_1.json")
                guard let data = try? Data(contentsOf: messageFile) else { continue }

                do {
                    let thread = try JSONDecoder().decode(FBMessageThread.self, from: data)
                    let threadId = threadDir.lastPathComponent
                    let participantNames = thread.participants.map { repairFacebookUTF8($0.name) }
                    let participantCount = participantNames.count
                    let isGroup = participantCount > 2

                    for msg in thread.messages {
                        allMessages.append(FacebookMessageDTO(
                            senderName: repairFacebookUTF8(msg.sender_name),
                            content: msg.content.map { repairFacebookUTF8($0) },
                            timestampMs: msg.timestamp_ms,
                            threadId: threadId,
                            threadTitle: repairFacebookUTF8(thread.title),
                            category: category,
                            isGroupThread: isGroup,
                            participantNames: participantNames,
                            participantCount: participantCount
                        ))
                    }
                } catch {
                    logger.warning("Failed to parse thread at \(threadDir.path): \(error)")
                }
            }
        }

        logger.debug("Parsed \(allMessages.count) messages across all threads")
        return allMessages
    }

    /// Parse comments from `your_facebook_activity/comments_and_reactions/comments.json`.
    /// Extracts the target person's name from the title field.
    func parseComments(in folder: URL) async -> [FacebookCommentDTO] {
        let url = folder.appending(path: "your_facebook_activity/comments_and_reactions/comments.json")
        guard let data = try? Data(contentsOf: url) else {
            logger.debug("No comments file found at \(url.path)")
            return []
        }

        do {
            let wrapper = try JSONDecoder().decode(FBCommentsWrapper.self, from: data)
            return wrapper.comments_v2.compactMap { raw -> FacebookCommentDTO? in
                let title = repairFacebookUTF8(raw.title)
                guard let targetName = parseCommentTargetName(from: title) else { return nil }
                let commentText = raw.data?.first?.comment?.comment
                return FacebookCommentDTO(
                    targetName: targetName,
                    commentText: commentText.map { repairFacebookUTF8($0) },
                    timestamp: Date(timeIntervalSince1970: TimeInterval(raw.timestamp))
                )
            }
        } catch {
            logger.error("Failed to parse comments JSON: \(error)")
            return []
        }
    }

    /// Parse reactions from `your_facebook_activity/comments_and_reactions/likes_and_reactions.json`.
    /// Extracts the post author's name from label_values when present.
    func parseReactions(in folder: URL) async -> [FacebookReactionDTO] {
        let url = folder.appending(path: "your_facebook_activity/comments_and_reactions/likes_and_reactions.json")
        guard let data = try? Data(contentsOf: url) else {
            logger.debug("No reactions file found at \(url.path)")
            return []
        }

        do {
            let rawItems = try JSONDecoder().decode([FBReactionItem].self, from: data)
            return rawItems.compactMap { raw -> FacebookReactionDTO? in
                guard let labels = raw.label_values else { return nil }
                let nameLabel = labels.first { $0.label == "Name" }
                guard let targetName = nameLabel?.value else { return nil }
                let reactionLabel = labels.first { $0.label == "Reaction" }
                return FacebookReactionDTO(
                    targetName: repairFacebookUTF8(targetName),
                    reactionType: reactionLabel?.value ?? "Like",
                    timestamp: Date(timeIntervalSince1970: TimeInterval(raw.timestamp))
                )
            }
        } catch {
            logger.error("Failed to parse reactions JSON: \(error)")
            return []
        }
    }

    /// Parse sent friend requests from `connections/friends/sent_friend_requests.json`.
    func parseSentFriendRequests(in folder: URL) async -> [FacebookFriendRequestDTO] {
        let url = folder.appending(path: "connections/friends/sent_friend_requests.json")
        guard let data = try? Data(contentsOf: url) else { return [] }

        do {
            let wrapper = try JSONDecoder().decode(FBSentRequestsWrapper.self, from: data)
            return wrapper.sent_requests_v2.map { raw in
                FacebookFriendRequestDTO(
                    name: repairFacebookUTF8(raw.name),
                    timestamp: Date(timeIntervalSince1970: TimeInterval(raw.timestamp)),
                    direction: .sent
                )
            }
        } catch {
            logger.error("Failed to parse sent friend requests: \(error)")
            return []
        }
    }

    /// Parse received friend requests from `connections/friends/received_friend_requests.json`.
    func parseReceivedFriendRequests(in folder: URL) async -> [FacebookFriendRequestDTO] {
        let url = folder.appending(path: "connections/friends/received_friend_requests.json")
        guard let data = try? Data(contentsOf: url) else { return [] }

        do {
            let wrapper = try JSONDecoder().decode(FBReceivedRequestsWrapper.self, from: data)
            return wrapper.received_requests_v2.map { raw in
                FacebookFriendRequestDTO(
                    name: repairFacebookUTF8(raw.name),
                    timestamp: Date(timeIntervalSince1970: TimeInterval(raw.timestamp)),
                    direction: .received
                )
            }
        } catch {
            logger.error("Failed to parse received friend requests: \(error)")
            return []
        }
    }

    /// Parse the user's own posts from `your_facebook_activity/posts/your_posts__check_ins__photos_and_videos_1.json`.
    func parsePosts(in folder: URL) async -> [FacebookPostDTO] {
        let url = folder.appending(path: "your_facebook_activity/posts/your_posts__check_ins__photos_and_videos_1.json")
        guard let data = try? Data(contentsOf: url) else {
            logger.debug("No posts file found at \(url.path)")
            return []
        }

        do {
            let rawPosts = try JSONDecoder().decode([FBPostItem].self, from: data)
            let posts = rawPosts.compactMap { raw -> FacebookPostDTO? in
                // Extract text from the first data element's "post" field
                guard let postText = raw.data?.first?.post, !postText.isEmpty else { return nil }
                let repairedText = repairFacebookUTF8(postText)
                let repairedTitle = raw.title.map { repairFacebookUTF8($0) }
                return FacebookPostDTO(
                    text: repairedText,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(raw.timestamp)),
                    title: repairedTitle
                )
            }
            let sorted = posts.sorted { $0.timestamp > $1.timestamp }
            logger.debug("Parsed \(sorted.count) text posts from Facebook export")
            return sorted
        } catch {
            logger.error("Failed to parse posts JSON: \(error)")
            return []
        }
    }

    // MARK: - UTF-8 Repair

    /// Repairs Facebook's mojibake encoding. Facebook exports encode UTF-8 as Latin-1,
    /// producing sequences like `\u00e2\u0080\u0094` for `—` (em dash).
    /// This converts the string's bytes from Latin-1 back to UTF-8.
    nonisolated func repairFacebookUTF8(_ string: String) -> String {
        guard let latin1Data = string.data(using: .isoLatin1) else { return string }
        return String(data: latin1Data, encoding: .utf8) ?? string
    }

    // MARK: - Comment Title Parsing

    /// Extracts the target person's name from a Facebook comment title string.
    /// Example: "David Snyder commented on Katie Faust's reel." → "Katie Faust"
    /// Returns nil for self-comments ("his own", "her own", "their own").
    nonisolated func parseCommentTargetName(from title: String) -> String? {
        // Pattern: "{author} commented on {target}'s {thing}."
        guard let commentedRange = title.range(of: " commented on ") else { return nil }
        let afterCommented = title[commentedRange.upperBound...]

        // Skip self-comments
        let selfPrefixes = ["his own", "her own", "their own", "your own"]
        for prefix in selfPrefixes {
            if afterCommented.hasPrefix(prefix) { return nil }
        }

        // Find the possessive "'s " to extract the name
        // Handle both standard apostrophe and Unicode right single quotation mark
        for possessive in ["'s ", "\u{2019}s "] {
            if let possessiveRange = afterCommented.range(of: possessive) {
                let name = String(afterCommented[afterCommented.startIndex..<possessiveRange.lowerBound])
                return name.isEmpty ? nil : name
            }
        }

        return nil
    }

    // MARK: - Name Normalization

    /// Normalizes a display name for matching: lowercased, diacritics folded,
    /// whitespace collapsed, trimmed.
    nonisolated func normalizeNameForMatching(_ name: String) -> String {
        name.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - DTOs (Public, Sendable)

/// A friend from the Facebook friend roster.
nonisolated public struct FacebookFriendDTO: Sendable {
    public let name: String
    public let friendedOn: Date
}

/// A single message from a Messenger thread.
nonisolated public struct FacebookMessageDTO: Sendable {
    public let senderName: String
    public let content: String?
    public let timestampMs: Int
    public let threadId: String
    public let threadTitle: String
    public let category: FacebookMessageCategory
    public let isGroupThread: Bool
    public let participantNames: [String]
    public let participantCount: Int

    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
    }
}

/// Classification of a Messenger thread location in the export.
nonisolated public enum FacebookMessageCategory: String, Sendable {
    case inbox    = "inbox"
    case e2ee     = "e2ee"
    case archived = "archived"
    case filtered = "filtered"

    /// Touch weight multiplier relative to inbox (1.0).
    public var weightMultiplier: Double {
        switch self {
        case .inbox:    return 1.0
        case .e2ee:     return 1.0
        case .archived: return 0.8
        case .filtered: return 0.3
        }
    }
}

/// A comment the user made on someone else's content.
nonisolated public struct FacebookCommentDTO: Sendable {
    public let targetName: String
    public let commentText: String?
    public let timestamp: Date
}

/// A reaction the user gave to someone's content.
nonisolated public struct FacebookReactionDTO: Sendable {
    public let targetName: String
    public let reactionType: String
    public let timestamp: Date
}

/// A friend request sent or received.
nonisolated public struct FacebookFriendRequestDTO: Sendable {
    public let name: String
    public let timestamp: Date
    public let direction: FacebookFriendRequestDirection
}

/// Direction of a friend request.
nonisolated public enum FacebookFriendRequestDirection: String, Sendable {
    case sent
    case received
}

// MARK: - Private JSON Decoding Structs

// -- Friends --

nonisolated private struct FBFriendsWrapper: Decodable, Sendable {
    let friends_v2: [FBFriendRaw]
}

nonisolated private struct FBFriendRaw: Decodable, Sendable {
    let name: String
    let timestamp: Int
}

// -- Profile --

nonisolated private struct FBProfileWrapper: Decodable, Sendable {
    let profile_v2: FBProfileRaw
}

nonisolated private struct FBProfileRaw: Decodable, Sendable {
    let name: FBProfileName
    let emails: FBProfileEmails?
    let birthday: FBBirthday?
    let gender: FBGender?
    let current_city: FBLocation?
    let hometown: FBLocation?
    let relationship: FBRelationship?
    let family_members: [FBFamilyMember]?
    let education_experiences: [FBEducation]?
    let work_experiences: [FBWork]?
    let websites: [FBWebsite]?
    let profile_uri: String?
}

nonisolated private struct FBProfileName: Decodable, Sendable {
    let full_name: String
    let first_name: String
    let middle_name: String?
    let last_name: String
}

nonisolated private struct FBProfileEmails: Decodable, Sendable {
    let emails: [String]?
}

nonisolated private struct FBBirthday: Decodable, Sendable {
    let year: Int
    let month: Int
    let day: Int
}

nonisolated private struct FBGender: Decodable, Sendable {
    let gender_option: String?
}

nonisolated private struct FBLocation: Decodable, Sendable {
    let name: String
}

nonisolated private struct FBRelationship: Decodable, Sendable {
    let status: String
    let partner: String?
}

nonisolated private struct FBFamilyMember: Decodable, Sendable {
    let name: String
    let relation: String
}

nonisolated private struct FBEducation: Decodable, Sendable {
    let name: String
    let school_type: String?
    let concentrations: [String]?
}

nonisolated private struct FBWork: Decodable, Sendable {
    let employer: String
    let title: String?
    let location: String?
}

nonisolated private struct FBWebsite: Decodable, Sendable {
    let address: String
}

// -- Messenger Threads --

nonisolated private struct FBMessageThread: Decodable, Sendable {
    let participants: [FBParticipant]
    let messages: [FBMessage]
    let title: String
    let is_still_participant: Bool?
    let thread_path: String?
}

nonisolated private struct FBParticipant: Decodable, Sendable {
    let name: String
}

nonisolated private struct FBMessage: Decodable, Sendable {
    let sender_name: String
    let timestamp_ms: Int
    let content: String?
    let is_geoblocked_for_viewer: Bool?
}

// -- Comments --

nonisolated private struct FBCommentsWrapper: Decodable, Sendable {
    let comments_v2: [FBCommentRaw]
}

nonisolated private struct FBCommentRaw: Decodable, Sendable {
    let timestamp: Int
    let title: String
    let data: [FBCommentData]?
}

nonisolated private struct FBCommentData: Decodable, Sendable {
    let comment: FBCommentContent?
}

nonisolated private struct FBCommentContent: Decodable, Sendable {
    let timestamp: Int?
    let comment: String?
    let author: String?
}

// -- Reactions --

nonisolated private struct FBReactionItem: Decodable, Sendable {
    let timestamp: Int
    let label_values: [FBLabelValue]?
}

nonisolated private struct FBLabelValue: Decodable, Sendable {
    let label: String
    let value: String
}

// -- Friend Requests --

nonisolated private struct FBSentRequestsWrapper: Decodable, Sendable {
    let sent_requests_v2: [FBFriendRequestRaw]
}

nonisolated private struct FBReceivedRequestsWrapper: Decodable, Sendable {
    let received_requests_v2: [FBFriendRequestRaw]
}

nonisolated private struct FBFriendRequestRaw: Decodable, Sendable {
    let name: String
    let timestamp: Int
}

// -- Posts --

nonisolated private struct FBPostItem: Decodable, Sendable {
    let timestamp: Int
    let data: [FBPostData]?
    let title: String?
}

nonisolated private struct FBPostData: Decodable, Sendable {
    let post: String?
}
