# SAM Facebook Integration Specification

**Version:** 1.0
**Date:** March 3, 2026
**Purpose:** Technical specification for building SAM's Facebook data import system, Messenger interaction scoring, profile analysis agent, and cross-platform profile consistency with the existing LinkedIn integration. Built to mirror the LinkedIn Integration Spec architecture while accounting for Facebook-specific data structures and relationship semantics.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Facebook Data Export: File Inventory & Schema](#2-facebook-data-export-file-inventory--schema)
3. [Data Categories & Classification](#3-data-categories--classification)
4. [Contact Import Pipeline](#4-contact-import-pipeline)
5. [Intentional Touch Detection & Scoring](#5-intentional-touch-detection--scoring)
6. [Unknown Contact Triage: Add vs Later](#6-unknown-contact-triage-add-vs-later)
7. [De-duplication & Merge Logic](#7-de-duplication--merge-logic)
8. [Facebook Profile Analysis Agent](#8-facebook-profile-analysis-agent)
9. [Cross-Platform Profile Consistency (Unlocks LinkedIn §11)](#9-cross-platform-profile-consistency)
10. [Data Model Extensions](#10-data-model-extensions)
11. [Implementation Phases](#11-implementation-phases)
12. [Agent Definitions](#12-agent-definitions)

---

## 1. Architecture Overview

SAM's Facebook integration operates through a **single primary channel** — unlike LinkedIn, which has both bulk import and real-time email monitoring:

**Channel A — Bulk Import (periodic):** The user downloads their Facebook data archive (Settings > Your Information > Download Your Information, JSON format). This produces a ZIP file containing structured JSON files. SAM ingests this, parses all relevant JSON, and builds/updates the relationship graph.

**Why no Channel B (email monitoring)?** Facebook notification emails are far less structured than LinkedIn's and carry minimal actionable relationship data. Facebook notification emails typically say "You have new notifications" with a link back to Facebook rather than including the actual content. The cost-benefit of parsing them is very low. Instead, SAM relies on periodic re-imports to refresh Facebook data.

### Key Differences from LinkedIn

| Aspect | LinkedIn | Facebook |
|--------|----------|----------|
| **Export format** | CSV files | JSON files |
| **Contact identity** | Profile URL (vanity slug) | Display name only (no profile URLs in friends list) |
| **Professional data** | Company, position, skills, endorsements | Employer, education (less structured) |
| **Messages** | Single CSV with all messages | Per-conversation JSON files in subdirectories |
| **Touch signals** | Messages, endorsements, recommendations, reactions, comments | Messages, comments, reactions, event co-attendance, group co-membership |
| **Email monitoring** | High-value (structured HTML emails) | Low-value (generic notification emails) |
| **Relationship nature** | Professional-first | Personal-first, with professional overlap |
| **Text encoding** | UTF-8 standard | Mojibake — Facebook exports use Latin-1 encoded UTF-8 (see §2.5) |

### Key Principles

- Facebook friend names are the **only reliable identifier** in the friends list — there are no profile URLs. Matching must rely on name + timestamp + cross-referencing with message thread names.
- The `profile_uri` field in `profile_information.json` (the user's own profile) provides the user's Facebook URL, but friends' profile URLs are NOT included in the export.
- Message thread directory names contain a numeric ID suffix (e.g., `ruthsnyder_10153029279158403`) which can serve as a stable thread identifier.
- Facebook data is **personal-first** — coaching suggestions must reflect a different tone than LinkedIn's professional focus. See §8 for the agent prompt.
- All social profile data feeds into the existing platform-agnostic `SocialProfileSnapshot` schema (LinkedIn §14).
- The `IntentionalTouch` model is already platform-agnostic (has a `platform` field). Facebook touches use `platform = "facebook"`.

---

## 2. Facebook Data Export: File Inventory & Schema

When the user downloads their Facebook data in JSON format, it contains the following directory structure. Not all files appear for every user.

### 2.1 Profile & Identity Files

| Path | Key Fields | Notes |
|------|-----------|-------|
| `personal_information/profile_information/profile_information.json` | name (first/last), emails, birthday, gender, current_city, hometown, relationship status/partner, family_members, education_experiences, work_experiences, websites, profile_uri | **Core identity.** Rich data about the user. Maps to `SocialProfileSnapshot` + `UserFacebookProfileDTO`. |
| `personal_information/profile_information/contact_info.json` | label_values (address, city, etc.), fbid | Contact info — usually sparse. |
| `personal_information/profile_information/websites.json` | URLs the user has listed | Websites on profile. |
| `personal_information/other_personal_information/contacts_uploaded_from_your_phone.json` | Phone contacts synced to Facebook | May contain phone numbers and names for cross-referencing. |

### 2.2 Contact & Network Files

| Path | Key Fields | Notes |
|------|-----------|-------|
| `connections/friends/your_friends.json` | `friends_v2[]`: name, timestamp | **Primary friend roster.** ~300 entries in sample. Only name + friendship timestamp. **No profile URLs, no emails, no company.** |
| `connections/friends/sent_friend_requests.json` | `sent_requests_v2[]`: name, timestamp | Outgoing friend requests (pending or rejected). Touch signal. |
| `connections/friends/received_friend_requests.json` | name, timestamp | Inbound friend requests. |
| `connections/friends/rejected_friend_requests.json` | name, timestamp | Requests the user rejected. |
| `connections/friends/removed_friends.json` | name, timestamp | Unfriended contacts. |
| `connections/friends/people_you_may_know.json` | name, timestamp | Facebook suggestions — low value. |
| `connections/friends/suggested_friends.json` | name, timestamp | More suggestions — low value. |
| `connections/followers/who_you've_followed.json` | name, timestamp | Pages/people followed. |

### 2.3 Intentional Touch Files

| Path | Touch Direction | Touch Weight | Notes |
|------|----------------|-------------|-------|
| `your_facebook_activity/messages/inbox/*/message_1.json` | Bidirectional | **HIGH** | Direct personal messages. Per-thread JSON with participants[] and messages[]. |
| `your_facebook_activity/messages/e2ee_cutover/*/message_1.json` | Bidirectional | **HIGH** | End-to-end encrypted message history (same schema as inbox). |
| `your_facebook_activity/messages/filtered_threads/*/message_1.json` | Inbound | **LOW** | Filtered/spam-like messages. |
| `your_facebook_activity/messages/archived_threads/*/message_1.json` | Bidirectional | **MEDIUM** | Archived conversations — user intentionally archived. |
| `your_facebook_activity/comments_and_reactions/comments.json` | Outbound | **MEDIUM** | Comments the user made on others' content. `title` field names the content owner. |
| `your_facebook_activity/comments_and_reactions/likes_and_reactions.json` | Outbound | **LOW** | Reactions with type (Like, Love, etc.) and sometimes `Name` label identifying post author. |
| `your_facebook_activity/events/your_event_responses.json` | Context | **LOW** | Events the user attended — indirect co-presence signal. |
| `your_facebook_activity/groups/your_groups.json` | Context | **NONE** | Group membership — context enrichment only. |
| `your_facebook_activity/groups/group_posts_and_comments.json` | Outbound | **LOW** | User's activity in groups. |
| `connections/friends/sent_friend_requests.json` | Outbound | **MEDIUM** | Deliberate relationship initiation. |
| `connections/friends/received_friend_requests.json` | Inbound | **MEDIUM** | Someone initiated relationship with user. |
| `logged_information/activity_messages/people_and_friends.json` | Context | **LOW** | Activity log entries referencing friend interactions (with fbid). |

### 2.4 Content & Activity Files

| Path | Notes |
|------|-------|
| `your_facebook_activity/facebook_marketplace/*` | Marketplace activity — conversation data may contain relationship signals for business contacts. |
| `your_facebook_activity/facebook_payments/*` | Payment history — may indicate financial relationships. |
| `your_facebook_activity/fundraisers/*` | Fundraiser activity. |
| `preferences/feed/unfollowed_profiles.json` | People the user chose to unfollow — negative signal. |

### 2.5 Text Encoding: Mojibake Problem

**Critical implementation note:** Facebook data exports encode text as Latin-1 interpreted UTF-8. This means multi-byte UTF-8 characters appear as mojibake sequences. For example:

```
Export shows:  "Katar\u00c3\u00adna \u00c5\u00bdilin\u00c4\u008d\u00c3\u00adkov\u00c3\u00a1"
Correct name:  "Katarína Žilinčíková"

Export shows:  "\u00e2\u0080\u0099" (three escaped bytes)
Correct char:  "'" (right single quotation mark, U+2019)

Export shows:  "\u00f0\u009f\u0098\u0085" (four escaped bytes)
Correct char:  "😅" (emoji)
```

**Fix:** After JSON deserialization, run a UTF-8 repair pass on all string values:
```swift
func repairFacebookUTF8(_ string: String) -> String {
    // The JSON string contains Unicode escape sequences (\u00XX) that represent
    // Latin-1 byte values. When these bytes are assembled and re-interpreted as
    // UTF-8, the correct characters emerge.
    guard let latin1Data = string.data(using: .isoLatin1) else { return string }
    return String(data: latin1Data, encoding: .utf8) ?? string
}
```

This repair must be applied to **all** text fields from the Facebook export: names, messages, comments, event names, etc.

### 2.6 What the Export Does NOT Include

- **Friends' profile URLs** — The friends list contains only names and timestamps. No way to directly link to a Facebook profile from the export data alone.
- **Friends' profile photos** — Not included.
- **Friends' employer/company** — Unlike LinkedIn, Facebook's friend export has no professional data.
- **Who liked/commented on YOUR posts** — Similar to LinkedIn's gap. Only your outbound activity is exported.
- **Friends' email addresses or phone numbers** — Not in the export (even if shared with you on Facebook).
- **Post content you published** — Not visible in this basic export (would require requesting "all data" or posts-specific export).
- **Story views** — Only aggregate counts, not viewer identities.

---

## 3. Data Categories & Classification

### Category A: Data About the User

**Includes:** `profile_information.json` (name, birthday, relationship, education, work, websites), `contact_info.json`, comments and reactions the user made (as activity signals), marketplace activity.

**Purpose:** Feeds the Facebook Profile Analysis Agent and Cross-Platform Consistency checks.

### Category B: Contact List Data

**Includes:** `your_friends.json` (primary roster), friend requests (sent/received/rejected/removed).

**Purpose:** Feeds the Contact Import Pipeline. Each friend becomes a candidate for SAM's relationship database.

### Category C: Intentional Touches

**Includes:** Messenger conversations (inbox, e2ee, archived), comments on others' posts (title field identifies content owner), reactions to others' posts (Name label identifies author), friend requests sent/received.

**Purpose:** Feeds the Intentional Touch Scoring system.

### Dual-Category Items

| Data | Categories | Reason |
|------|-----------|--------|
| User's comments on others' posts | A + C | Activity about the user AND a touch toward the post owner |
| Marketplace conversations | Potentially B + C | May reveal business relationships and constitute touches |
| Event RSVPs | A + C (weak) | Activity about the user AND weak co-presence signal |

---

## 4. Contact Import Pipeline

### 4.1 Import Trigger

The user provides the Facebook data export ZIP file via file picker or drag-and-drop in Settings > Integrations > Facebook. The folder structure must contain at minimum `connections/friends/your_friends.json`.

### 4.2 Processing Steps

```
Step 1: Locate and validate the Facebook export folder structure
Step 2: Repair UTF-8 encoding on all parsed text (§2.5)
Step 3: Parse profile_information.json → build user's own Facebook profile
Step 4: Parse your_friends.json → build candidate contact list
Step 5: For each friend, attempt matching against existing SAM contacts (Section 7)
Step 6: Parse all Messenger threads (inbox + e2ee_cutover + archived)
Step 7: Parse comments, reactions, friend requests for additional touches
Step 8: Score each candidate's intentional touch history (Section 5)
Step 9: Classify each NEW contact as "Add" or "Later" (Section 6)
Step 10: Parse profile data for Facebook Profile Analysis Agent (Section 8)
Step 11: Store import audit record with timestamps
Step 12: Present results to user in import review UI
```

### 4.3 Facebook Friend Identity

Unlike LinkedIn, Facebook friends have **no profile URL** in the export. The primary identifier is:

- `name` — Display name as shown on Facebook (subject to mojibake repair)
- `timestamp` — Unix epoch when the friendship was established

**Thread directory names** provide an additional identifier: e.g., `ruthsnyder_10153029279158403` contains a numeric suffix that represents a Facebook-internal ID. While this isn't a direct profile URL, it can be used as a stable thread reference.

The `people_and_friends.json` activity log entries contain `fbid` fields (e.g., `"fbid": "1520554595"`) which are Facebook numeric user IDs. These can be cross-referenced to reconstruct profile URLs as `https://www.facebook.com/profile.php?id={fbid}`, though this is fragile.

### 4.4 Friend Record Fields

From `your_friends.json`, SAM extracts:

```
name: String          // Display name (UTF-8 repaired)
friendedOn: Date      // From Unix timestamp
```

Enriched from message parsing:

```
messengerThreadId: String?   // Directory name suffix if messages exist
messageCount: Int            // Total messages exchanged
lastMessageDate: Date?       // Most recent message timestamp
```

---

## 5. Intentional Touch Detection & Scoring

### 5.1 Touch Sources from Bulk Import

| Touch Type | Source | Matching Strategy | Weight |
|-----------|--------|-------------------|--------|
| Direct message sent/received | `messages/inbox/*/message_1.json` | Match participant name to friend name | **10** per message |
| E2EE message sent/received | `messages/e2ee_cutover/*/message_1.json` | Same as inbox | **10** per message |
| Archived message | `messages/archived_threads/*/message_1.json` | Same as inbox | **8** per message (slightly lower — user archived) |
| Filtered message | `messages/filtered_threads/*/message_1.json` | Same as inbox | **3** per message (Facebook filtered it) |
| Comment on their post | `comments.json` | Parse `title` field: "David Snyder commented on {Name}'s {thing}" | **6** |
| Reaction to their post | `likes_and_reactions.json` | `Name` label value identifies post author | **3** |
| Friend request sent | `sent_friend_requests.json` | Direct name match | **5** |
| Friend request received | `received_friend_requests.json` | Direct name match | **5** |
| Event co-attendance | `your_event_responses.json` | Name in event title (weak signal) | **1** |

### 5.2 Message Thread Parsing

Message threads are the richest touch source for Facebook. Each thread directory contains a `message_1.json` with this structure:

```json
{
  "participants": [
    { "name": "Andrea Wilhoit" },
    { "name": "David Snyder" }
  ],
  "messages": [
    {
      "sender_name": "Andrea Wilhoit",
      "timestamp_ms": 1591964228270,
      "content": "This event is the weekend...",
      "is_geoblocked_for_viewer": false
    }
  ]
}
```

**Parsing rules:**
- The `participants` array identifies the conversation partners. For 1:1 threads, the non-user participant is the contact.
- Group threads (3+ participants) contribute touches to ALL non-user participants, but at reduced weight (÷ participant count, minimum 1).
- `timestamp_ms` is milliseconds since epoch (divide by 1000 for Date).
- Messages may include `photos`, `files`, `videos`, `share` (with `link`) — these indicate richer engagement but don't change touch weight.
- Messages with `content` of "X sent an attachment." have no text but still count as a touch.
- All `sender_name` and `content` fields must be UTF-8 repaired (§2.5).

### 5.3 Comment Attribution

The `comments.json` `title` field follows patterns like:
- `"David Snyder commented on Cherie Evans's photo."`
- `"David Snyder commented on his own photo."`
- `"David Snyder commented on Katie Faust's reel."`

**Extraction:** Parse the name between "commented on " and "'s " to identify the post author. Skip "his own" / "her own" / "their own" entries (self-comments).

### 5.4 Reaction Attribution

The `likes_and_reactions.json` entries use a `label_values` array structure:

```json
{
  "timestamp": 1771861871,
  "label_values": [
    { "label": "Reaction", "value": "Like" },
    { "label": "URL", "value": "https://...", "href": "https://..." },
    { "label": "Name", "value": "Sarah Kovin Snyder" }
  ]
}
```

**Extraction:** Look for a `label_values` entry with `"label": "Name"` — this identifies the post author. Not all reactions have a Name label (page posts, for example). Only create touches when a person name is identifiable.

### 5.5 Score Calculation

Identical to LinkedIn's scoring engine, but with Facebook-specific touch types:

```swift
// Reuse existing IntentionalTouchScore and TouchScoringEngine
// Add FacebookTouchType variants that map to existing TouchType enum values
// or extend TouchType with new cases as needed

// Recency bonus: touches within last 6 months get 1.5× multiplier (same as LinkedIn)
// A friend with totalScore > 0 defaults to .add classification
```

---

## 6. Unknown Contact Triage: Add vs Later

### 6.1 Classification Logic

Identical to LinkedIn §6 — any friend with `intentionalTouchScore > 0` defaults to `.add`, otherwise `.later`.

### 6.2 Import Review UI

Reuse the same two-section review sheet pattern as `LinkedInImportReviewSheet`:

**"Recommended to Add"** (score > 0, sorted by score descending):
- Row shows: name, message count, last message date, touch summary
- Note: Facebook provides less professional context than LinkedIn (no company/position) — so message frequency and recency are the primary decision signals

**"No Recent Interaction"** (score = 0, sorted by friendship date descending):
- Row shows: name, friendship date

### 6.3 The "Later" Bucket

Same lifecycle as LinkedIn's Later bucket — collapsible section in Today view, re-promotion on new touch data from subsequent imports. No "Never" option.

---

## 7. De-duplication & Merge Logic

### 7.1 Matching Priority

Facebook matching is harder than LinkedIn because there are **no profile URLs** in the friends list. Matching relies on names:

```
Priority 1: Facebook profile URL match
    - If a SamPerson already has a stored Facebook profile URL
      (from a previous import or manual entry), match on that.
    - This is the highest-confidence match but rarely available initially.

Priority 2: Cross-platform name match with LinkedIn data
    - If the Facebook friend's name matches an existing SamPerson
      AND that person has LinkedIn data with a similar company/position,
      flag as a PROBABLE match with high confidence.
    - Facebook names tend to be more informal ("Bobby Smith" vs
      LinkedIn's "Robert Smith"), so use fuzzy matching.

Priority 3: Apple Contacts name match
    - Match against Apple Contacts by name (accent-normalized, fuzzy).
    - If matched, check if the Apple Contact has a Facebook URL in
      social profiles — if so, upgrade to EXACT match.

Priority 4: Name-only fuzzy match against existing SAM contacts
    - Case-insensitive, accent-normalized first + last name match.
    - Flag as PROBABLE match requiring user confirmation.
    - Higher ambiguity than LinkedIn (no company/position to disambiguate).
```

### 7.2 Name Normalization Challenges

Facebook names present unique challenges:
- **Informal names:** "Bobby" vs "Robert", "Jenny" vs "Jennifer"
- **Couple accounts:** "LarrynLinda Merino" (two people sharing one account)
- **Business/page names in friends list:** "Accra Gillbt Guesthouse", "Chateau d'Etude"
- **Name variations over time:** Users change Facebook names (maiden/married, nicknames)
- **Multi-part names:** "Kahunapule Michael Paul Johnson", "Jo Ann Berg Megahan"

**Pragmatic approach:** For name matching, use the same accent-normalization and fuzzy matching as LinkedIn, but with a **lower auto-confidence threshold**. More matches should be flagged as PROBABLE rather than EXACT.

### 7.3 Duplicate Friend Detection

The Facebook friends list sometimes contains duplicate entries for the same person (e.g., "Ruth T Keako" timestamp 1600501815 and "Ruth Keako" timestamp 1665102204). SAM should detect these:

**Detection signals:**
- Two entries with very similar names (Levenshtein distance ≤ 3 after normalization)
- Same name appearing at different timestamps

**When detected:** Present as a single candidate in the review UI with a note: "May appear twice in your Facebook friends list."

---

## 8. Facebook Profile Analysis Agent

### 8.1 Purpose

After each Facebook data import, SAM runs an AI agent that analyzes the user's Facebook profile data. The tone is fundamentally different from the LinkedIn agent — Facebook is personal and community-oriented, not professional/keyword-optimized.

### 8.2 Agent Input

```swift
struct FacebookProfileAnalysisInput {
    // Identity
    let fullName: String
    let currentCity: String?
    let hometown: String?
    let birthday: (year: Int, month: Int, day: Int)?
    let relationship: (status: String, partner: String?)?
    let familyMembers: [(name: String, relation: String)]

    // Background
    let workExperiences: [(employer: String, title: String?, location: String?)]
    let educationExperiences: [(name: String, schoolType: String?, concentrations: [String])]
    let websites: [String]

    // Activity metrics (from import data)
    let friendCount: Int
    let messageThreadCount: Int          // total Messenger threads
    let activeThreadCount: Int           // threads with messages in last 12 months
    let totalMessagesExchanged: Int
    let commentsMade: Int
    let reactionsGiven: Int
    let groupsMembered: Int
    let eventsAttended: Int

    // Network characteristics
    let friendsByYear: [Int: Int]        // year → count of friendships established
    let topContactsByMessageVolume: [(name: String, messageCount: Int)]

    // Previous analysis
    let previousAnalysis: FacebookProfileAnalysisResult?
    let previousAnalysisDate: Date?
}
```

### 8.3 Agent Prompt Template

```
You are a Facebook presence advisor for a professional who uses Facebook primarily
for personal and community relationships — not as a professional networking platform.
This person works in financial services (WFG) and uses Facebook to maintain personal
connections with friends, family, church community, and extended social circles.

Unlike LinkedIn (which is about professional visibility and keyword optimization),
Facebook presence is about:
- Maintaining authentic personal connections
- Being approachable and trustworthy in the community
- Staying visible to friends and acquaintances (who may become referral sources)
- Sharing personal milestones and community involvement
- Not appearing "salesy" or overly promotional

Analyze the following Facebook profile data and provide:

1. CONNECTION HEALTH:
   - How active is this person on Facebook? (message frequency, comment/reaction patterns)
   - Are they maintaining a broad social circle or concentrated on a few contacts?
   - Friend count trend over the years — growing, stable, or stagnant?
   - Ratio of active conversations to total friends

2. COMMUNITY VISIBILITY:
   - Is this person visible in their community on Facebook?
   - Group participation assessment
   - Event engagement level
   - Do they comment on and react to others' content regularly?
   - Suggestions for low-effort ways to stay visible (reactions, brief comments,
     sharing community events)

3. RELATIONSHIP MAINTENANCE:
   - Identify any patterns in communication frequency
   - Are there long-dormant relationships that might be worth reviving?
   - Suggest natural touchpoints (birthdays, anniversaries, life events)
     for reconnecting

4. PROFILE COMPLETENESS:
   - Is the profile filled out enough to be recognizable and approachable?
   - Current city, hometown, workplace, education — are these up to date?
   - Website link — is it present and current?
   - Profile photo guidance (not visible in export, but note if metadata suggests none)

5. CROSS-REFERRAL POTENTIAL:
   - Based on community involvement and friend circle characteristics,
     identify natural opportunities where personal Facebook relationships
     could generate professional referrals WITHOUT being pushy
   - Frame suggestions as "being helpful in your community" rather than
     "prospecting on Facebook"
   - Example: "Your church community connections could benefit from a
     financial literacy workshop — this positions you as helpful, not salesy"

IMPORTANT BOUNDARIES:
- Never suggest "posting about your business" on Facebook
- Never suggest turning Facebook into a sales channel
- Focus on authentic relationship maintenance that NATURALLY leads to trust
- The user's professional presence belongs on LinkedIn; Facebook is personal
- If this is a FOLLOW-UP analysis, note what has changed since last time

Format your response as structured JSON matching the ProfileAnalysisDTO schema.
```

### 8.4 Agent Output

Reuse the existing `ProfileAnalysisDTO` structure with Facebook-specific category names:

```swift
// Categories for Facebook analysis:
// - "Connection Health" (replaces "Network Health")
// - "Community Visibility" (replaces "Content Strategy")
// - "Relationship Maintenance" (new, Facebook-specific)
// - "Profile Completeness" (replaces "Profile Improvements")
// - "Cross-Referral Potential" (new, Facebook-specific)
```

---

## 9. Cross-Platform Profile Consistency (Unlocks LinkedIn §11)

### 9.1 Why Facebook Unlocks §11

LinkedIn §11 (Cross-Platform Profile Consistency) was deferred because it requires data from at least two platforms. Facebook is the second platform. Once Facebook import is built, SAM can compare:

| Field | LinkedIn | Facebook | Consistency Check |
|-------|----------|----------|------------------|
| Name | From Profile.csv | From profile_information.json | Should match (may differ in formality) |
| Current employer | From Positions.csv | From work_experiences | Should be identical |
| Current title | From Positions.csv | From work_experiences | Should be identical |
| Location | From Profile.csv | From current_city | Should match |
| Education | From Education.csv | From education_experiences | Should match |
| Websites | From Profile.csv | From websites | Should be listed on both |
| Bio/About | LinkedIn summary | Not in basic FB export | N/A for initial pass |

### 9.2 Cross-Platform Friend Overlap

SAM can identify people who appear on both LinkedIn and Facebook by name matching:

```
For each Facebook friend:
    Search LinkedIn connections by fuzzy name match
    If match found:
        → Flag as cross-platform contact
        → Enrich SAM contact with both platform identifiers
        → Enable cross-platform touch scoring (combined LinkedIn + Facebook score)
```

This is valuable because:
- A person who is both a LinkedIn connection AND a Facebook friend has higher relationship significance
- Cross-platform touches compound: a LinkedIn endorsement + a Facebook message indicates strong multi-dimensional relationship
- The cross-platform consistency agent can compare how the user presents to this person on each platform

---

## 10. Data Model Extensions

### 10.1 New Models

```swift
// Represents a Facebook data import event
// Pattern: mirrors LinkedInImport
@Model
class FacebookImport {
    var id: UUID
    var importDate: Date
    var archiveFileName: String
    var friendCount: Int
    var matchedContactCount: Int
    var newContactsFound: Int
    var touchEventsFound: Int
    var messageThreadsParsed: Int
    var statusRawValue: String      // ImportStatus raw value
}
```

### 10.2 Existing Models Reused (No Changes Needed)

- **`IntentionalTouch`** — Already platform-agnostic. Facebook touches use `platform = "facebook"`.
- **`SocialProfileSnapshot`** — Already platform-agnostic. Stores the user's Facebook profile.
- **`ProfileAnalysisRecord`** — Already platform-agnostic. Stores Facebook analysis results.
- **`UnknownSender`** — Already used for LinkedIn Later contacts. Extend for Facebook Later contacts.

### 10.3 UnknownSender Extensions

Add optional fields for Facebook-specific metadata (same pattern as LinkedIn extensions):

```swift
// New optional fields on UnknownSender:
var facebookFriendedOn: Date?           // When the friendship was established
var facebookMessageCount: Int           // default 0 — total messages in export
var facebookLastMessageDate: Date?      // Most recent message timestamp
```

### 10.4 TouchType Extensions

Extend the existing `TouchType` enum with Facebook-specific cases if needed, or map Facebook touches to existing types:

| Facebook Touch | Maps to Existing TouchType | New Case Needed? |
|---------------|---------------------------|------------------|
| Messenger message | `.message` | No |
| Comment on their post | `.comment` | No |
| Reaction to their post | `.reaction` | No |
| Friend request sent | `.invitation` | No |
| Friend request received | `.invitation` | No |
| Event co-attendance | — | Yes: `.eventCoAttendance` (weight 1) |
| Archived message | `.message` | No (use existing with lower weight) |

### 10.5 Schema Change

This requires a schema bump (SAM_v30 → SAM_v31 or as appropriate) for:
- New `FacebookImport` model
- New optional fields on `UnknownSender`
- Possible new `TouchType` case

---

## 11. Implementation Phases

### Phase FB-1: Core Import Pipeline & Friend Parsing
**Scope:** Parse friends list, build candidates, basic matching, review UI

**Files to create:**
- `Services/FacebookService.swift` — JSON parsers for all Facebook export files, UTF-8 repair utility
- `Models/DTOs/FacebookImportCandidateDTO.swift` — Facebook-specific import candidate DTO (mirrors LinkedIn)
- `Models/DTOs/UserFacebookProfileDTO.swift` — User's own Facebook profile DTO
- `Coordinators/FacebookImportCoordinator.swift` — Import flow orchestration

**Files to modify:**
- `Models/SAMModels-Social.swift` — Add `FacebookImport` model
- `Models/SAMModels-UnknownSender.swift` — Add Facebook optional fields
- `Views/Settings/` — Add Facebook import settings section

**Deliverables:**
- Parse `your_friends.json` with UTF-8 repair
- Parse `profile_information.json` for user's own profile → store as `UserFacebookProfileDTO`
- Match friends against existing SAM contacts (Priority 1–4 matching)
- Build `FacebookImportCandidate` list sorted by match status
- Present import review sheet (reuse `LinkedInImportReviewSheet` pattern)
- Route "Add" contacts to Apple Contacts creation, "Later" to UnknownSender
- Store `FacebookImport` audit record

### Phase FB-2: Messenger Thread Parsing & Touch Scoring
**Scope:** Parse all message threads, compute intentional touch scores, enrich import candidates

**Files to modify:**
- `FacebookService.swift` — Add Messenger thread parsers
- `FacebookImportCoordinator.swift` — Integrate touch scoring into import flow
- `Repositories/IntentionalTouchRepository.swift` — Bulk insert Facebook touches (already platform-agnostic)

**Deliverables:**
- Recursively discover and parse all `message_1.json` files in inbox/, e2ee_cutover/, archived_threads/, filtered_threads/
- Handle group threads (3+ participants) with reduced per-person weighting
- Parse comments.json for comment attribution (extract name from title)
- Parse likes_and_reactions.json for reaction attribution (extract from Name label)
- Parse sent/received friend requests as touch events
- Run `TouchScoringEngine` with Facebook touch data
- Enrich import candidates with touch scores
- Update review sheet to show message count, last message date, touch summary

### Phase FB-3: User Profile Intelligence & Analysis Agent
**Scope:** Parse user's own profile for AI coaching context, build Facebook profile analysis agent

**Files to create:**
- `Services/FacebookProfileAnalystService.swift` — Facebook-specific profile analysis agent (§8)

**Files to modify:**
- `Services/BusinessProfileService.swift` — Add Facebook profile context fragment to AI system prompts
- `FacebookService.swift` — Parse work_experiences, education_experiences, family_members

**Deliverables:**
- Assemble `UserFacebookProfileDTO` from profile data
- Store as JSON in BusinessProfileService (same pattern as LinkedIn)
- Add `## Facebook Profile` section to `contextFragment()` for AI coaching prompts
- Implement Facebook profile analysis agent with the personal-tone prompt (§8.3)
- Store results in `ProfileAnalysisRecord` with `platform = "facebook"`
- Surface analysis in a new Facebook section of the Business Intelligence view

### Phase FB-4: Cross-Platform Consistency (LinkedIn §11)
**Scope:** Compare LinkedIn and Facebook profiles, identify cross-platform contacts, unlock §11

**Files to create:**
- `Services/CrossPlatformConsistencyService.swift` — Cross-platform comparison agent

**Deliverables:**
- Compare user's LinkedIn profile vs Facebook profile for inconsistencies
- Identify friends who appear on both platforms by fuzzy name matching
- Merge touch scores across platforms for cross-platform contacts
- Implement cross-platform consistency agent (LinkedIn §11.2 prompt)
- Store results in a new `CrossPlatformConsistencyResult`
- Surface in Business Intelligence view

### Phase FB-5: Apple Contacts Facebook URL Sync
**Scope:** Write Facebook profile URLs back to Apple Contacts (mirrors LinkedIn §13)

**Deliverables:**
- For "Add" contacts where a Facebook URL can be reconstructed (via fbid from activity data or manual entry), offer to write it to Apple Contacts
- Batch confirmation dialog (same pattern as `AppleContactsSyncConfirmationSheet`)
- Auto-sync toggle in Settings

### Phase FB-6: Polish & Documentation
**Scope:** Settings UI, documentation, edge cases

**Deliverables:**
- Full Facebook section in Settings > Integrations
- Import history (audit records)
- Re-import detection (warn if same archive imported twice)
- Stale data warning ("Facebook data last imported X days ago")
- Update context.md and changelog.md

---

## 12. Agent Definitions

### 12.1 Agent Registry (Facebook-specific)

| Agent Name | Trigger | Input | Output | Schedule |
|-----------|---------|-------|--------|----------|
| `FacebookProfileAnalyzer` | After bulk import + monthly | UserFacebookProfileDTO + activity metrics | ProfileAnalysisResult | On import, then monthly |
| `CrossPlatformConsistencyChecker` | After Facebook import (since LinkedIn data exists) | LinkedIn + Facebook SocialProfileSnapshots | CrossPlatformConsistencyResult | On import of 2nd platform |

### 12.2 Reused Agents (No Changes)

| Agent Name | Facebook Relevance |
|-----------|-------------------|
| `EngagementBenchmarker` | Can benchmark Facebook activity once data exists |
| `MessageReplyAdvisor` | Not applicable — no real-time Facebook monitoring |
| `NotificationSetupAdvisor` | Not applicable — no Facebook email monitoring |

---

## Appendix A: Facebook Data Export Request Instructions

```
Direct navigation to download your information:
1. Open Facebook > Settings & Privacy > Settings
2. Click "Your Information" in the left sidebar
3. Click "Download Your Information"
4. Select format: JSON (NOT HTML)
5. Select date range: "All time" for initial import
6. Media quality: Low (SAM doesn't need photos/videos)
7. Click "Request a Download"
8. Facebook will notify you when the archive is ready (usually 1-24 hours)
9. Download the ZIP file and provide it to SAM

Direct URL: https://www.facebook.com/dyi/?referrer=yfi_settings
```

## Appendix B: Facebook Export Folder Structure Reference

```
facebook-{username}/
├── ads_information/                    [IGNORE - not relationship data]
├── apps_and_websites_off_of_facebook/  [IGNORE]
├── connections/
│   ├── followers/
│   │   └── who_you've_followed.json
│   └── friends/
│       ├── your_friends.json           ★ PRIMARY FRIEND ROSTER
│       ├── sent_friend_requests.json   ★ TOUCH DATA
│       ├── received_friend_requests.json ★ TOUCH DATA
│       ├── rejected_friend_requests.json
│       ├── removed_friends.json
│       ├── people_you_may_know.json    [LOW VALUE]
│       └── suggested_friends.json      [LOW VALUE]
├── logged_information/
│   ├── activity_messages/
│   │   └── people_and_friends.json     ★ ACTIVITY LOG WITH FBIDS
│   ├── interactions/
│   │   ├── recently_viewed.json
│   │   └── recently_visited.json
│   └── location/                       [CONTEXT ONLY]
├── personal_information/
│   ├── profile_information/
│   │   ├── profile_information.json    ★ USER'S OWN PROFILE
│   │   ├── contact_info.json
│   │   └── websites.json
│   └── other_personal_information/
│       └── contacts_uploaded_from_your_phone.json [CROSS-REF]
├── preferences/
│   └── feed/
│       └── unfollowed_profiles.json    [NEGATIVE SIGNAL]
├── security_and_login_information/     [IGNORE]
└── your_facebook_activity/
    ├── comments_and_reactions/
    │   ├── comments.json               ★ TOUCH DATA (outbound)
    │   └── likes_and_reactions.json     ★ TOUCH DATA (outbound)
    ├── events/
    │   └── your_event_responses.json   ★ CO-ATTENDANCE SIGNAL
    ├── groups/
    │   ├── your_groups.json            [CONTEXT ONLY]
    │   └── group_posts_and_comments.json [LOW VALUE]
    ├── messages/
    │   ├── inbox/*/message_1.json      ★ PRIMARY TOUCH DATA
    │   ├── e2ee_cutover/*/message_1.json ★ PRIMARY TOUCH DATA
    │   ├── archived_threads/*/message_1.json ★ TOUCH DATA
    │   └── filtered_threads/*/message_1.json [LOW VALUE]
    ├── facebook_marketplace/           [BUSINESS RELATIONSHIP SIGNALS]
    └── facebook_payments/              [FINANCIAL RELATIONSHIP SIGNALS]
```

## Appendix C: Tone & Audience Comparison — LinkedIn vs Facebook Coaching

| Dimension | LinkedIn Agent Tone | Facebook Agent Tone |
|-----------|-------------------|-------------------|
| **Primary goal** | Professional visibility & credibility | Authentic personal connection |
| **Success metric** | Profile views, engagement rate, connection quality | Relationship maintenance, community presence |
| **Content advice** | Post 2-4x/week, optimize for keywords | Stay visible through comments/reactions, share personal milestones |
| **Never suggest** | Being too casual or personal | Being salesy or promotional |
| **Relationship framing** | "This contact could be a valuable professional connection" | "This is someone from your community — staying connected matters" |
| **Improvement language** | "Optimize your headline for discoverability" | "Keep your profile current so old friends can find you" |
| **Business crossover** | Direct: "This builds your professional brand" | Indirect: "Trust in your community naturally creates referral opportunities" |
