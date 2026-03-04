# SAM LinkedIn Integration Specification

**Version:** 1.0
**Date:** March 3, 2026
**Purpose:** Technical specification for Sonnet 4.6 to rebuild SAM's LinkedIn import system, email notification monitoring, profile analysis agents, and cross-platform profile consistency within Xcode (Swift 6, SwiftUI, SwiftData).

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [LinkedIn Data Export: File Inventory & Schema](#2-linkedin-data-export-file-inventory--schema)
3. [Data Categories & Classification](#3-data-categories--classification)
4. [Contact Import Pipeline](#4-contact-import-pipeline)
5. [Intentional Touch Detection & Scoring](#5-intentional-touch-detection--scoring)
6. [Unknown Contact Triage: Add vs Later](#6-unknown-contact-triage-add-vs-later)
7. [De-duplication & Merge Logic](#7-de-duplication--merge-logic)
8. [LinkedIn Email Notification Monitor](#8-linkedin-email-notification-monitor)
9. [Notification Setup Guidance System](#9-notification-setup-guidance-system)
10. [Profile Analysis Agent](#10-profile-analysis-agent)
11. [Cross-Platform Profile Consistency](#11-cross-platform-profile-consistency)
12. [Engagement Benchmarking & Suggestions](#12-engagement-benchmarking--suggestions)
13. [Apple Contacts Sync](#13-apple-contacts-sync)
14. [Data Model (SwiftData)](#14-data-model-swiftdata)
15. [Agent Definitions](#15-agent-definitions)

---

## 1. Architecture Overview

SAM's LinkedIn integration operates through two complementary channels:

**Channel A — Bulk Import (periodic):** The user downloads their LinkedIn data archive (Settings > Data Privacy > Get a copy of your data > "Download larger data archive"). This produces a ZIP file containing CSV and HTML files. SAM ingests this ZIP, parses all relevant CSVs, and builds/updates the relationship graph.

**Channel B — Real-Time Event Stream (continuous):** SAM monitors the user's Gmail inbox for LinkedIn notification emails. It parses the full HTML email body to detect new intentional touches (messages, endorsements, comments, connection requests, mentions, reactions to the user's content). This channel fills gaps the bulk import cannot cover — particularly inbound engagement on the user's posts.

**Channel C — Profile Analysis (on-demand + periodic):** After each bulk import and on a configurable schedule, SAM runs AI agents that analyze the user's profile data, content performance, and engagement patterns. Results feed into weekly/monthly summaries.

### Key Principles

- LinkedIn member IDs (the unique numeric identifier embedded in profile URLs) are the primary key for all contact matching.
- SAM stores metadata + first 200 characters of message content. Full conversations remain on LinkedIn.
- The "Later" bucket is a living list, always visible in the Today view, that re-ranks as new touch data arrives.
- All social media profile data is stored in a platform-agnostic schema so cross-platform agents can operate uniformly.

---

## 2. LinkedIn Data Export: File Inventory & Schema

When the user requests the full archive, LinkedIn delivers a ZIP containing the following CSV files (and occasionally HTML folders). Not all files appear for every user — LinkedIn only includes files relevant to the user's activity.

### 2.1 Profile & Identity Files

| File | Key Fields | Notes |
|------|-----------|-------|
| `Profile.csv` | firstName, lastName, headline, summary, industry, location, websites | Core identity. Map to `SocialProfile` model. |
| `Positions.csv` | companyName, title, description, location, startDate, endDate | Work history. Store as `ProfileExperience` entries. |
| `Education.csv` | schoolName, degree, fieldOfStudy, startDate, endDate | Education history. |
| `Skills.csv` | skillName | Flat list of self-declared skills. |
| `Certifications.csv` | certName, authority, startDate, endDate, url | Professional certifications. |
| `Honors.csv` | title, description, issuer, date | Honors listed on profile. |
| `Projects.csv` | title, description, url, startDate, endDate | Projects listed on profile. |
| `Publications.csv` | title, publisher, date, url, description | Publications listed on profile. |
| `Photos/` | (folder of image files) | Profile pictures and uploaded images. |
| `Registration.csv` | registeredDate, ipAddress, subscriptionType, invitedBy | Account creation metadata. |
| `Account Status History.csv` | date, event (created/closed/reopened) | Account lifecycle. |
| `Ad Targeting.csv` | (various inferred interest fields) | LinkedIn's ad targeting data about the user. Low priority for SAM. |
| `Receipts.csv` | date, description, amount | Billing history (Premium, Sales Nav, etc.). |
| `Security Challenges.csv` | date, ipAddress, country, challengeType | Login security events. |

### 2.2 Contact & Network Files

| File | Key Fields | Notes |
|------|-----------|-------|
| `Connections.csv` | firstName, lastName, emailAddress, company, position, connectedOn, profileUrl | **Primary contact roster.** The profileUrl contains the member identifier. Email is only present if the connection has sharing enabled (increasingly rare). |
| `Imported Contacts.csv` | firstName, lastName, emailAddress, (other fields vary) | Contacts the user has uploaded to LinkedIn from their address book. These are NOT necessarily LinkedIn members. |

### 2.3 Intentional Touch Files

| File | Key Fields | Touch Direction | Touch Weight |
|------|-----------|----------------|-------------|
| `Messages.csv` | from, to, date, subject, content, senderProfileUrl, recipientProfileUrls | Bidirectional | **HIGH** — Direct personal communication |
| `Invitations.csv` | direction (incoming/outgoing), senderProfileUrl, date, message | Bidirectional | **HIGH** — Deliberate relationship initiation |
| `Endorsements_Given.csv` | endorserName, endorserProfileUrl, skillName, endorsementDate, status | Inbound (others → user) | **MEDIUM** — Intentional but low-effort |
| `Endorsements_Received.csv` | endorseeName, endorseeProfileUrl, skillName, endorsementDate, status | Outbound (user → others) | **MEDIUM** |
| `Recommendations_Given.csv` | recommenderName, recommenderProfileUrl, company, title, recommendationText, date | Inbound (others → user) | **VERY HIGH** — Significant effort and trust |
| `Recommendations_Received.csv` | recommendeeName, recommendeeProfileUrl, company, title, recommendationText, date, status | Outbound (user → others) | **VERY HIGH** |
| `Reactions.csv` | reactionType, date, postUrl | Outbound (user → others' content) | **LOW** — Intentional but minimal effort |
| `Comments.csv` | commentText, date, postUrl | Outbound (user → others' content) | **MEDIUM** — Requires thought and composition |

### 2.4 Content & Activity Files

| File | Key Fields | Notes |
|------|-----------|-------|
| `Shares.csv` | shareDate, shareComment, shareMediaUrl, visibility | User's shortform posts. Key input for profile analysis agent. |
| `Articles/` | (folder of HTML files) | User's longform articles/newsletters. |
| `Group Comments.csv` | comment, discussionTitle, groupName, groupUrl, date | Comments in LinkedIn Groups. |
| `Group Likes.csv` | likedText, date, postUrl | Likes within Groups. |
| `Group Posts.csv` | postTitle, postContent, date, groupName, postUrl | Discussions user started in Groups. |
| `Search Queries.csv` | searchDate, query | User's LinkedIn searches. Low priority. |
| `Events.csv` | eventName, date, externalUrl | Events the user was invited to. |

### 2.5 What the Export Does NOT Include

This is critical for understanding the gap that email notifications must fill:

- **Who viewed your profile** — not exported, notifications are anonymized
- **Who liked/commented on YOUR posts** — you get YOUR reactions to others, but not others' reactions to you
- **Newsletter subscriber identities** — not in personal data export (only available via Company Page analytics)
- **Who you follow / who follows you** — follower lists with profile details are not included
- **People You May Know suggestions** — not exported
- **InMail messages** (for Premium users) — may or may not be included in Messages.csv depending on account type

---

## 3. Data Categories & Classification

Every piece of imported data falls into one of three categories:

### Category A: Data About the User

Data the user has posted about themselves, plus reputation signals from others about the user.

**Includes:** Profile.csv, Positions.csv, Education.csv, Skills.csv, Certifications.csv, Honors.csv, Projects.csv, Publications.csv, Photos, Registration.csv, Shares.csv, Articles/, Endorsements_Given.csv (endorsements OF the user), Recommendations_Given.csv (recommendations OF the user).

**Purpose:** Feeds the Profile Analysis Agent and Cross-Platform Consistency checks.

### Category B: Contact List Data

The roster of people in the user's network.

**Includes:** Connections.csv (primary), Imported Contacts.csv (supplementary).

**Purpose:** Feeds the Contact Import Pipeline. Each row becomes a candidate for SAM's relationship database.

### Category C: Intentional Touches

Activities requiring deliberate effort by either party, directed at a specific person.

**Includes:** Messages.csv, Invitations.csv (with personalized messages), Endorsements (both directions), Recommendations (both directions), Reactions.csv, Comments.csv, Group interactions (when directed at identifiable individuals).

**Purpose:** Feeds the Intentional Touch Scoring system, which determines Add vs Later classification.

### Dual-Category Items

Some data falls into multiple categories:

| Data | Categories | Reason |
|------|-----------|--------|
| Endorsements received | A + C | Describes user's skills AND is an intentional touch from another person |
| Recommendations received | A + C | Describes user's reputation AND is a significant intentional touch |
| User's comments on others' posts | C (primarily) | Touch directed at the post author |
| Shares/Articles | A (primarily) | Content about the user, but engagement on these (via email channel) creates C data |

---

## 4. Contact Import Pipeline

### 4.1 Import Trigger

The user initiates import by providing the LinkedIn data archive ZIP file to SAM (via file picker or drag-and-drop). SAM should also detect if a LinkedIn data export email arrives in Gmail and prompt the user to download and import it.

### 4.2 Processing Steps

```
Step 1: Unzip archive
Step 2: Validate expected CSV files exist (warn if key files missing)
Step 3: Parse Connections.csv → build candidate contact list
Step 4: For each candidate, extract LinkedIn member ID from profileUrl
Step 5: Match against existing SAM contacts (see Section 7: De-duplication)
Step 6: Parse all Intentional Touch files (Section 2.3)
Step 7: Score each candidate's intentional touch history (Section 5)
Step 8: Classify each NEW contact as "Add" or "Later" (Section 6)
Step 9: Parse Profile/Content files for Profile Analysis Agent (Section 10)
Step 10: Store all raw import data with timestamps for historical comparison
Step 11: Present results to user in import review UI
```

### 4.3 LinkedIn Member ID Extraction

The LinkedIn profile URL typically follows one of these patterns:

```
https://www.linkedin.com/in/{vanity-name}
https://www.linkedin.com/in/{vanity-name}-{alphanumeric-suffix}
```

The `profileUrl` field in Connections.csv contains this URL. SAM should store:

- `linkedInProfileUrl` — the full URL as-is (this is the stable reference)
- `linkedInVanityName` — extracted slug portion after `/in/`

Note: LinkedIn does NOT expose a raw numeric member ID in the data export. The profile URL (specifically the vanity name slug) serves as the de facto unique identifier. Users CAN change their vanity URL, so SAM should also store the original URL from each import and detect changes.

### 4.4 Connection Record Fields

From `Connections.csv`, SAM extracts:

```
firstName: String
lastName: String
emailAddress: String? (often nil — most users have sharing disabled)
company: String?
position: String?
connectedOn: Date
linkedInProfileUrl: String (primary identifier)
```

---

## 5. Intentional Touch Detection & Scoring

### 5.1 Touch Sources from Bulk Import

For each contact in Connections.csv, SAM scans the intentional touch files to find any activity between the user and that contact. Matching is done by comparing the contact's `linkedInProfileUrl` against profile URLs in touch files.

| Touch Type | Source File | Field to Match | Weight |
|-----------|------------|---------------|--------|
| Direct message sent/received | Messages.csv | senderProfileUrl, recipientProfileUrls | 10 |
| Personalized invitation | Invitations.csv | senderProfileUrl + message content present | 8 |
| Generic invitation (no message) | Invitations.csv | senderProfileUrl + no message | 2 |
| Recommendation written for user | Recommendations_Given.csv | recommenderProfileUrl | 15 |
| Recommendation user wrote for them | Recommendations_Received.csv | recommendeeProfileUrl | 15 |
| Endorsement of user's skill | Endorsements_Given.csv | endorserProfileUrl | 5 |
| User endorsed their skill | Endorsements_Received.csv | endorseeProfileUrl | 5 |
| User reacted to their content | Reactions.csv | (requires URL → author mapping) | 3 |
| User commented on their content | Comments.csv | (requires URL → author mapping) | 6 |

### 5.2 Touch Score Calculation

```swift
struct IntentionalTouchScore {
    let contactProfileUrl: String
    let totalScore: Int
    let touchCount: Int
    let mostRecentTouch: Date
    let touchTypes: Set<TouchType>
    let hasDirectMessage: Bool
    let hasRecommendation: Bool
}
```

**Scoring rules:**

- Each touch event adds its weight to `totalScore`
- Multiple messages count individually (each message = +10)
- Recency bonus: touches within the last 6 months get 1.5x multiplier
- A contact with `totalScore > 0` (any intentional touch beyond a bare connection) is classified as having intentional touches

### 5.3 Limitation: Reaction/Comment Author Resolution

Reactions.csv and Comments.csv contain the URL of the POST the user reacted to or commented on, but NOT the author's profile URL directly. To attribute these touches to a specific contact, SAM would need to map post URLs to authors, which the export does not directly support.

**Pragmatic approach:** SAM should still store these touch events with the post URL. If SAM can resolve the author (e.g., the user identifies them, or the email notification channel provides context), it can retroactively credit the touch. Otherwise, these touches are "unattributed" and do not influence Add/Later classification.

---

## 6. Unknown Contact Triage: Add vs Later

### 6.1 Classification Logic

When a LinkedIn contact is imported and does NOT match any existing SAM contact:

```
IF intentionalTouchScore.totalScore > 0
    (meaning ANY intentional touch beyond bare connection exists)
THEN default = .add
ELSE default = .later
```

The user can override any classification manually.

### 6.2 Import Review UI

Present the import results as two sections:

**"Recommended to Add" section** (defaults to Add):
- Sorted by intentional touch score descending (most engaged contacts first)
- Each row shows: name, company, position, touch summary (e.g., "12 messages, 1 recommendation, connected 2019-03-15")
- Toggle to switch to "Later" if user disagrees

**"No Recent Interaction" section** (defaults to Later):
- Sorted by connection date descending (most recent connections first)
- Each row shows: name, company, position, connected date
- Toggle to switch to "Add" if user knows them

**Batch actions:**
- "Add All Recommended" button
- "Add All" button (adds everything including Later)
- Individual toggles per contact

### 6.3 The "Later" Bucket Lifecycle

The Later list is NOT a dead end. It is a living, visible part of SAM's Today view:

**Today View Presentation:**
- The Later list appears as a collapsible section in the Today view
- Default state: collapsed, showing a count badge (e.g., "47 LinkedIn contacts to review")
- When expanded: sorted by touch recency (contacts with the most recent intentional touch — which may have arrived via email notification AFTER initial import — appear first)
- Contacts with zero touches sort by connection date

**Promotion Logic:**
- When SAM's email notification monitor detects a new intentional touch involving a "Later" contact, that contact is automatically re-promoted: its sort position moves to the top of the Later list AND SAM highlights it with a visual indicator (e.g., "New activity" badge)
- SAM does NOT auto-move contacts from Later to Add without user action. The user always makes the final decision.

**There is no "Never" option.** Every LinkedIn connection remains reviewable. The collapsible UI ensures the list doesn't create noise, while the re-promotion logic ensures no relationship signal is lost.

---

## 7. De-duplication & Merge Logic

### 7.1 Matching Priority

When processing each record from Connections.csv, SAM attempts to match it against existing SAM contacts in this order:

```
Priority 1: LinkedIn Profile URL match
    - Compare the imported linkedInProfileUrl against any stored LinkedIn URLs
      in existing SAM contacts
    - This is the highest-confidence match because LinkedIn URLs are unique
    - NOTE: Users can change their vanity URL. If SAM previously stored a URL
      that no longer matches, fall through to Priority 2

Priority 2: LinkedIn URL stored in Apple Contacts
    - If SAM has synced contacts from Apple Contacts and any of those records
      contain a LinkedIn URL in their social profiles or URL fields, match on that

Priority 3: Email match
    - If the imported record includes an email address, match against known
      email addresses in SAM contacts

Priority 4: Name + Company fuzzy match
    - If firstName + lastName match (case-insensitive, accent-normalized) AND
      company matches (fuzzy — handle abbreviations like "Inc" vs "Inc.")
    - Flag as PROBABLE match, present to user for confirmation
    - Do NOT auto-merge on name+company alone
```

### 7.2 Match Outcomes

```
EXACT_MATCH (Priority 1 or 2):
    → Update existing SAM contact with latest LinkedIn data
    → Merge any new touch data
    → Log the update with timestamp

PROBABLE_MATCH (Priority 3 or 4):
    → Flag for user review
    → Show both records side by side
    → User confirms merge or marks as separate people

NO_MATCH:
    → New contact candidate
    → Route through Add/Later classification (Section 6)
```

### 7.3 Duplicate LinkedIn Account Detection

Some LinkedIn users create multiple accounts (same real person, different LinkedIn profiles). SAM should detect this scenario:

**Detection signals:**
- Two records in Connections.csv with very similar names (Levenshtein distance ≤ 2) but different profile URLs
- Two records with the same email address but different profile URLs
- An imported record that name-matches an existing SAM contact who already has a DIFFERENT LinkedIn URL stored

**When detected:**
- If confidence is HIGH (same email + similar name + one account has no recent activity): auto-merge, keeping the more recently active account as primary and storing the other as an alias
- If confidence is AMBIGUOUS (similar names, different emails, both active): flag for user review with a clear explanation: "These two LinkedIn profiles may belong to the same person. [Name A - URL A - last active date] vs [Name B - URL B - last active date]. Merge or keep separate?"

**Staleness indicator:** If one of the duplicate accounts has no activity in the touch files while the other does, SAM should note this: "This may be an abandoned account. The active profile appears to be [URL]."

### 7.4 Data Staleness Management

SAM uses the email notification channel (Section 8) to patch contact data incrementally between full imports:

- **Job change notifications:** When LinkedIn sends an email like "John Smith started a new position at Acme Corp," SAM updates John's company and position fields and timestamps the change
- **Name changes:** Rare but possible. If a notification references a known LinkedIn URL but with a different name, SAM flags for review.
- **Stale data warning:** SAM tracks the date of the last full import. If > 90 days have passed, SAM adds a reminder to the Today view: "Your LinkedIn data was last imported [X days ago]. Consider downloading a fresh export for the most accurate contact information."

---

## 8. LinkedIn Email Notification Monitor

### 8.1 Overview

SAM continuously monitors the user's Gmail inbox for emails from LinkedIn. It parses the full HTML body to extract intentional touch events and route them to the appropriate SAM subsystems.

### 8.2 Email Detection

**Sender identification:**

LinkedIn sends notification emails from these addresses:
```
messages-noreply@linkedin.com
invitations@linkedin.com
notifications-noreply@linkedin.com
inmail-hit-reply@linkedin.com
jobs-noreply@linkedin.com
endorsements@linkedin.com
recommendations@linkedin.com
news@linkedin.com
```

SAM should match on the domain `@linkedin.com` broadly, then classify by the local part and/or subject line patterns.

**Email classification by intentional touch relevance:**

| Email Type | Detection Pattern (subject line) | Touch Value | Action |
|-----------|--------------------------------|-------------|--------|
| Direct message | "sent you a message" or "new message from" | **HIGH** | Extract sender, timestamp, snippet. Create touch event. |
| Connection request | "wants to connect" or "invitation to connect" | **HIGH** | Extract sender, any personalized message. Create touch event. |
| Connection accepted | "accepted your invitation" | **MEDIUM** | Extract person. Update connection status. |
| Endorsement | "endorsed you for" | **MEDIUM** | Extract endorser and skill. Create touch event. |
| Recommendation | "has recommended you" | **VERY HIGH** | Extract recommender. Create touch event. Alert user. |
| Comment on your post | "commented on your post" | **MEDIUM** | Extract commenter. Create touch event. This fills the export gap. |
| Reaction to your post | "reacted to your post" or "likes your post" | **LOW** | Extract reactor. Create touch event. This fills the export gap. |
| Mention | "mentioned you" | **MEDIUM** | Extract mentioner. Create touch event. |
| Profile view | "viewed your profile" or "appeared in X searches" | **NONE** | Ignore — usually anonymized, not a directed touch. |
| Job change | "started a new position" or "work anniversary" | **NONE** (not a touch) | Use for data staleness patching (Section 7.4). |
| Birthday | "birthday" | **NONE** (not a touch) | Optionally surface as a prompt for user to initiate a touch. |
| Newsletter subscriber | "subscribed to your newsletter" | **MEDIUM** | Extract subscriber if identified. Create touch event. |
| News/articles | "trending" or "top stories" or "daily rundown" | **NONE** | Ignore. |
| Job alerts | "jobs you may be interested in" | **NONE** | Ignore. |
| Tips from LinkedIn | "tips" or "suggestions" or "who to follow" | **NONE** | Ignore. |

### 8.3 HTML Email Parsing

LinkedIn notification emails have a consistent HTML structure. SAM should parse:

```swift
struct LinkedInEmailParser {
    /// Parses a LinkedIn notification email's full HTML body
    /// Returns a structured event or nil if the email is not touch-relevant

    func parse(htmlBody: String, subject: String, from: String, date: Date)
        -> LinkedInNotificationEvent?

    // Key extraction targets within the HTML:
    // 1. Contact name — usually in a <a> tag linking to their profile
    // 2. Contact LinkedIn URL — href of the profile link
    // 3. Action type — derived from subject line + body text patterns
    // 4. Content snippet — the first ~200 chars of any message body,
    //    comment text, or endorsement detail
    // 5. Timestamp — from email headers (more reliable than body text)
}

struct LinkedInNotificationEvent {
    let eventType: LinkedInEventType
    let contactName: String
    let contactProfileUrl: String?
    let snippet: String?      // first 200 chars of message/comment content
    let date: Date
    let rawSubject: String
    let sourceEmailId: String  // Gmail message ID for reference
}

enum LinkedInEventType {
    case directMessage
    case connectionRequest
    case connectionAccepted
    case endorsement(skill: String?)
    case recommendation
    case commentOnPost
    case reactionToPost(reactionType: String?)
    case mention
    case newsletterSubscription
    case jobChange(newCompany: String?, newTitle: String?)
    case birthday
    case other(description: String)
}
```

### 8.4 Event Routing

When SAM detects a LinkedIn notification event:

```
1. Attempt to match contactProfileUrl to existing SAM contact
2. If matched AND contact is in "Add" state:
     → Create touch event in contact's timeline
     → If eventType is .directMessage:
         → Surface in Today view with "Reply suggestion" prompt
         → The reply suggestion should include context from recent touches
3. If matched AND contact is in "Later" state:
     → Create touch event
     → Re-promote contact to top of Later list with "New activity" badge
4. If NOT matched to any SAM contact:
     → Store event in an "unmatched events" queue
     → When next bulk import runs, attempt to retroactively match
     → If the event is a connectionRequest, it may represent someone
       not yet in Connections.csv (they'll appear after acceptance)
5. If eventType is .jobChange:
     → Update contact's company/position fields (Section 7.4)
6. If eventType is .directMessage:
     → Always surface in Today view regardless of contact status
     → Include snippet and "Open in LinkedIn" deep link
     → Generate reply suggestion (see Section 8.5)
```

### 8.5 Message Reply Suggestions

When SAM detects an inbound LinkedIn message, it should help the user respond without opening LinkedIn manually:

```swift
struct MessageReplySuggestion {
    let contactName: String
    let contactContext: String       // SAM's relationship summary for this person
    let messageSnippet: String       // first 200 chars from the notification
    let suggestedApproach: String    // AI-generated guidance
    let linkedInDeepLink: URL        // linkedin://messaging/thread/{threadId} or web URL
    let lastTouchSummary: String     // "Last exchanged messages 3 months ago about..."
}
```

**Suggestion generation:**
SAM should compose a brief suggestion using the contact's relationship context (role, company, history of touches, any notes the user has stored) combined with the message snippet. The suggestion is NOT a draft reply — it is guidance like:

> "John Smith (VP Engineering at Acme, connected 2020, last messaged about the ABT board search in November) sent you a message about [snippet]. Consider responding within 24 hours given his seniority. You might reference your shared connection through the ABT network."

**Deep linking:**
SAM should construct a URL that opens the LinkedIn messaging thread directly:
- Web: `https://www.linkedin.com/messaging/thread/{conversationId}/` (if conversation ID can be extracted from email)
- Fallback: `https://www.linkedin.com/messaging/` (general inbox)
- Mobile app: `linkedin://messaging/` (if LinkedIn app is installed)

---

## 9. Notification Setup Guidance System

### 9.1 Detection of Missing Notifications

SAM should track which types of LinkedIn notification emails it has seen over a rolling 30-day window. If certain high-value notification types have NEVER appeared, SAM should create a suggested task for the user.

**Expected notification types (SAM should see at least one of each within 30-60 days of active LinkedIn use):**

| Type | Email Pattern | If Missing After 30 Days |
|------|-------------|------------------------|
| Messages | "sent you a message" | Critical — suggest immediately |
| Connection requests | "wants to connect" | Important — suggest at 14 days |
| Endorsements | "endorsed you for" | Moderate — suggest at 30 days |
| Comments on posts | "commented on your post" | Important — suggest at 30 days (only if user has posted) |
| Reactions to posts | "reacted to your post" | Low — suggest at 60 days (only if user has posted) |

**If the user has NO LinkedIn emails at all after 7 days:** SAM should surface a high-priority task: "SAM isn't detecting any LinkedIn notification emails. This may mean your LinkedIn email notifications are turned off. Set them up so SAM can track your relationship activity."

### 9.2 Guidance Task Creation

When SAM detects missing notifications, it creates a task in the Today view:

```swift
struct NotificationSetupTask {
    let title: String
    // e.g., "Enable LinkedIn message notifications"
    let explanation: String
    // e.g., "SAM monitors your email for LinkedIn notifications to track
    //  relationship activity. Message notifications haven't been detected.
    //  Enable them so SAM can alert you to new messages and suggest replies."
    let instructions: [SetupStep]
    let directUrl: URL
    // https://www.linkedin.com/psettings/communications
    let priority: TaskPriority
}
```

### 9.3 Step-by-Step Instructions

SAM should present clear instructions that take the user directly to the right place. Here are the instructions for each notification type:

**General navigation (all types start here):**
```
1. Open https://www.linkedin.com/psettings/communications
   (This goes directly to Settings > Communications — no menu hunting needed)
2. You will see notification categories listed on the page
```

**For Messages:**
```
Title: "Enable LinkedIn Message Email Notifications"
URL: https://www.linkedin.com/psettings/communications

Steps:
1. Open the link above (takes you directly to notification settings)
2. Look for the category "Conversations" or "Messages"
3. Click on it to expand the options
4. Find "Messages" and click the pencil/edit icon
5. Under "Email," select "Individual email" (not "Weekly digest" or "Off")
6. Your changes save automatically

Why this matters: When someone sends you a LinkedIn message, SAM will
detect it in your email and can alert you with context about who they
are and suggest how to respond — without you needing to open LinkedIn.
```

**For Connection Requests:**
```
Title: "Enable LinkedIn Connection Request Notifications"
URL: https://www.linkedin.com/psettings/communications

Steps:
1. Open the link above
2. Look for "Invitations and messages" or "Network" category
3. Click to expand
4. Find "Invitations to connect" and click the pencil/edit icon
5. Under "Email," select "Individual email"
6. Changes save automatically

Why this matters: SAM can detect new connection requests and help you
decide whether to accept based on your existing relationship data.
```

**For Endorsements:**
```
Title: "Enable LinkedIn Endorsement Notifications"
URL: https://www.linkedin.com/psettings/communications

Steps:
1. Open the link above
2. Look for "Activity that involves you" or "Profile" category
3. Click to expand
4. Find "Endorsements" and click the pencil/edit icon
5. Under "Email," select "Individual email" or "Weekly digest"
6. Changes save automatically

Why this matters: When someone endorses your skills, it's a sign they're
thinking of you professionally. SAM tracks these as relationship signals.
```

**For Comments and Reactions on Your Posts:**
```
Title: "Enable LinkedIn Post Engagement Notifications"
URL: https://www.linkedin.com/psettings/communications

Steps:
1. Open the link above
2. Look for "Posting and commenting" category
3. Click to expand
4. Find "Comments and reactions" and click the pencil/edit icon
5. Under "Email," select "Individual email"
6. Changes save automatically

Why this matters: This is especially important because LinkedIn's data
export does NOT include who comments on or reacts to your posts. Email
notifications are the ONLY way SAM can capture this relationship data.
```

### 9.4 Presentation

The notification setup tasks should:
- Appear in the Today view as actionable cards
- Include a "Open Settings" button that launches the direct URL
- Include a "Dismiss — I'll do this later" option (re-surfaces after 7 days)
- Include a "Already done" option (SAM verifies by checking for the notification type in subsequent emails)
- Not nag — after 3 dismissals, drop to monthly reminders

---

## 10. Profile Analysis Agent

### 10.1 Purpose

After each bulk import, SAM runs an AI agent that analyzes the user's LinkedIn profile data and content to provide constructive feedback. The tone should be encouraging — praise what's working well and suggest specific improvements.

### 10.2 Agent Input

The agent receives:

```swift
struct LinkedInProfileAnalysisInput {
    // Identity
    let headline: String?
    let summary: String?
    let industry: String?
    let location: String?
    let websites: [String]?

    // Experience
    let positions: [Position]         // from Positions.csv
    let education: [Education]        // from Education.csv
    let skills: [String]              // from Skills.csv
    let certifications: [Certification]

    // Reputation signals
    let endorsementsReceived: [Endorsement]  // who endorsed what skills
    let recommendationsReceived: [Recommendation]

    // Content
    let shares: [Share]               // from Shares.csv — shortform posts
    let articles: [Article]           // from Articles/ folder
    let shareCount: Int
    let articleCount: Int

    // Engagement (from email notification data)
    let recentCommentCount: Int       // comments on user's posts (last 90 days)
    let recentReactionCount: Int      // reactions on user's posts (last 90 days)

    // Network
    let connectionCount: Int
    let connectionsByYear: [Int: Int] // year → count of connections made that year

    // Previous analysis (if any)
    let previousAnalysis: ProfileAnalysisResult?
    let previousAnalysisDate: Date?
}
```

### 10.3 Agent Prompt Template

```
You are a LinkedIn profile optimization advisor analyzing a professional's
LinkedIn presence. Your tone is encouraging and constructive — always lead
with genuine praise before suggesting improvements.

Analyze the following LinkedIn profile data and provide:

1. PRAISE (what's working well):
   - Highlight strong areas of the profile
   - Note impressive endorsement/recommendation patterns
   - Call out good content creation habits if present
   - Acknowledge network growth trends

2. PROFILE IMPROVEMENTS (specific, actionable):
   - Headline effectiveness (is it descriptive and keyword-rich?)
   - Summary completeness and tone
   - Skills list relevance and completeness
   - Recommendation gaps (who should they ask?)
   - Any missing sections (certifications, projects, etc.)

3. CONTENT STRATEGY (if they create content):
   - Posting frequency assessment
   - Content type mix (posts vs articles vs shares)
   - Engagement patterns
   - Suggestions for topics based on their expertise

4. NETWORK HEALTH:
   - Connection growth trend
   - Ratio of endorsed connections vs total connections
   - Recommendation reciprocity

If this is a FOLLOW-UP analysis (previous analysis data provided),
note what has improved since last time and what recommendations
remain unaddressed.

Format your response as structured JSON with these sections.
```

### 10.4 Agent Output

```swift
struct ProfileAnalysisResult: Codable {
    let analysisDate: Date
    let platform: SocialPlatform   // .linkedIn
    let overallScore: Int          // 1-100
    let praise: [PraiseItem]
    let improvements: [ImprovementSuggestion]
    let contentStrategy: ContentStrategyAssessment?
    let networkHealth: NetworkHealthAssessment
    let changesSinceLastAnalysis: [ChangeNote]?  // nil if first analysis
}

struct PraiseItem: Codable {
    let category: String           // e.g., "Recommendations", "Content"
    let message: String
    let metric: String?            // e.g., "15 recommendations received"
}

struct ImprovementSuggestion: Codable {
    let category: String
    let priority: Priority         // .high, .medium, .low
    let suggestion: String
    let rationale: String
    let exampleOrPrompt: String?   // concrete example or AI prompt they could use
}
```

### 10.5 When SAM Cannot Generate Suggestions Alone

For complex content strategy questions where SAM's local AI capabilities may be insufficient, SAM should offer a pre-composed prompt the user can paste into an online AI:

```swift
struct ExternalAIPromptSuggestion {
    let context: String
    // "SAM has identified that your LinkedIn posting frequency has dropped.
    //  For detailed content strategy suggestions, you could ask an AI assistant:"
    let prompt: String
    // "I'm a [role] in [industry] with [X] LinkedIn connections. I typically
    //  post about [topics from Shares analysis]. My posts average [Y] reactions.
    //  I want to increase engagement. Suggest 10 post topics and a posting
    //  schedule that would work for someone in my position."
    let copyButtonLabel: String
    // "Copy Prompt"
}
```

---

## 11. Cross-Platform Profile Consistency

### 11.1 Platform-Agnostic Profile Storage

All social media profile data is stored in a unified schema that supports platform-specific extensions. This enables cross-platform agents to compare and ensure consistency.

```swift
// Core model — platform-agnostic
struct SocialProfile {
    let id: UUID
    let platform: SocialPlatform       // .linkedIn, .facebook, .twitter, etc.
    let platformUserId: String          // platform-specific unique ID
    let platformProfileUrl: String
    let importDate: Date
    let rawData: Data                   // original CSV/JSON preserved

    // Normalized identity fields
    let displayName: String
    let firstName: String?
    let lastName: String?
    let headline: String?               // LinkedIn headline, Facebook bio, Twitter bio
    let summary: String?                // LinkedIn summary, Facebook "About", etc.
    let profileImageData: Data?

    // Normalized professional fields
    let currentCompany: String?
    let currentTitle: String?
    let industry: String?
    let location: String?
    let websites: [String]

    // Platform-specific structured data
    let experience: [ProfileExperience]
    let education: [ProfileEducation]
    let skills: [String]

    // Content metrics (snapshot at import time)
    let connectionOrFriendCount: Int?
    let followerCount: Int?
    let postCount: Int?

    // Platform-specific extensions (stored as JSON)
    let platformSpecificData: [String: Any]
    // LinkedIn: endorsements, recommendations, certifications, etc.
    // Facebook: groups, pages managed, life events, etc.
}

enum SocialPlatform: String, Codable {
    case linkedIn
    case facebook
    case twitter
    case instagram
    // extensible for future platforms
}
```

### 11.2 Cross-Platform Consistency Agent

This agent compares profile data across platforms to ensure important information is consistent where it should be and appropriately tailored where it should differ.

**Fields that SHOULD be consistent across platforms:**
- Name (first, last) — should match everywhere
- Current employer and title — factual, should be the same
- Location — should be consistent
- Professional websites — should be listed everywhere relevant
- Profile photo — should be recognizably the same person (professional on LinkedIn, may be more casual on Facebook)

**Fields that SHOULD differ by platform:**
- Headline/bio — LinkedIn should be professional and keyword-optimized; Facebook can be more personal
- Summary/About — LinkedIn emphasizes professional value proposition; Facebook emphasizes personal interests and community
- Content topics — LinkedIn content should be industry-focused; Facebook can include personal interests
- Tone — LinkedIn is professional; Facebook is conversational

**Agent prompt template:**
```
You are a cross-platform social media profile consistency advisor.
Compare the following profiles for the same person across platforms.

Identify:
1. INCONSISTENCIES that should be fixed (different job titles, outdated
   info on one platform, missing key information)
2. APPROPRIATE DIFFERENCES that are good (platform-appropriate tone,
   different emphasis for different audiences)
3. MISSING OPPORTUNITIES (information present on one platform that would
   benefit from being added to another, adapted to that platform's style)

For each finding, specify which platform and what action to take.
Consider that LinkedIn's audience is professional peers and recruiters,
while Facebook's audience is a mix of personal and professional contacts.
```

### 11.3 Agent Output

```swift
struct CrossPlatformConsistencyResult: Codable {
    let analysisDate: Date
    let platformsCompared: [SocialPlatform]
    let inconsistencies: [ConsistencyIssue]
    let appropriateDifferences: [AppropriateVariation]
    let missingOpportunities: [CrossPlatformSuggestion]
}

struct ConsistencyIssue: Codable {
    let field: String               // e.g., "currentTitle"
    let platformValues: [String: String]  // platform → value
    let severity: Severity          // .high, .medium, .low
    let suggestion: String
}

struct CrossPlatformSuggestion: Codable {
    let sourceField: String         // where the info exists
    let sourcePlatform: SocialPlatform
    let targetPlatform: SocialPlatform
    let suggestion: String          // how to adapt it
    let platformAppropriateVersion: String  // suggested text for target
}
```

---

## 12. Engagement Benchmarking & Suggestions

### 12.1 Contextual Benchmarking Approach

SAM's engagement benchmarking agent decides contextually whether to use the user's own historical trend, industry/role-based benchmarks, or both. The agent's decision depends on available data:

- **First analysis (no history):** Use general benchmarks for the user's industry/role + connection count
- **Subsequent analyses:** Compare against the user's own previous metrics AND general benchmarks
- **When user has strong history (6+ months of data):** Weight personal trend more heavily than external benchmarks

### 12.2 Metrics Tracked

```swift
struct EngagementMetrics: Codable {
    let platform: SocialPlatform
    let period: DateInterval           // e.g., last 30 days

    // Content creation
    let postsCreated: Int
    let articlesPublished: Int
    let averagePostLength: Int?        // word count

    // Engagement received (from email notification data)
    let totalReactionsReceived: Int
    let totalCommentsReceived: Int
    let totalSharesReceived: Int
    let uniqueEngagers: Int            // distinct people who engaged

    // Engagement given (from bulk import)
    let reactionsGiven: Int
    let commentsWritten: Int

    // Network growth
    let newConnectionsThisPeriod: Int
    let endorsementsReceived: Int
    let recommendationsReceived: Int

    // Derived metrics
    let engagementRate: Double?        // (reactions + comments) / posts
    let averageEngagementPerPost: Double?
    let reciprocityRatio: Double?      // engagement given / engagement received
}
```

### 12.3 Benchmarking Agent Prompt Template

```
You are a social media engagement analyst. Evaluate the user's engagement
metrics for {platform} and provide an honest, encouraging assessment.

Your approach:
- If this is the FIRST analysis, compare against general benchmarks for
  someone with {connectionCount} connections in {industry}
- If previous data exists, compare against the user's own trend AND
  general benchmarks
- Use your judgment about which comparison is more meaningful given
  the data available

Provide:
1. OVERALL ASSESSMENT: Is engagement meeting, exceeding, or falling below
   expectations? One clear sentence.

2. If EXCEEDING expectations:
   - Specific congratulations with metrics cited
   - What's driving the success
   - How to sustain it

3. If MEETING expectations:
   - Acknowledgment that things are on track
   - One or two specific suggestions to level up

4. If BELOW expectations:
   - Encouraging framing (never critical or discouraging)
   - 2-3 specific, actionable suggestions ranked by impact
   - If you can't provide detailed enough suggestions, compose a prompt
     the user could paste into an online AI for more detailed help

5. TREND: If previous data exists, note the direction (improving,
   stable, declining) and by how much

General benchmarks (approximate, adjust for context):
- Posting frequency: 2-4 times per week is strong for most professionals
- Engagement rate: 2-5% of connection count per post is healthy
- Comments are worth ~5x reactions in relationship value
- Reciprocity matters: engaging with others' content drives engagement back
```

### 12.4 Integration with Weekly/Monthly Summaries

**Weekly summary (brief):**
- If engagement is exceeding expectations: Include a one-line congratulations. E.g., "Your LinkedIn engagement is up 23% this month — your post about [topic] was especially well-received."
- If below expectations: Include a gentle nudge. E.g., "You haven't posted on LinkedIn in 2 weeks. Even a short comment on an industry article helps keep your profile visible."

**Monthly summary (detailed):**
- Full benchmarking analysis
- Trend charts if data exists
- Top-performing content highlights
- Specific improvement suggestions
- Cross-platform consistency check results
- If the user has been making improvements based on previous suggestions, acknowledge that explicitly

### 12.5 Congratulations Pacing

SAM should not over-congratulate. Rules:
- Maximum one engagement congratulation per weekly summary
- Only congratulate on genuinely notable achievements (not "you got 2 likes")
- If engagement has been consistently strong for 3+ months, shift from congratulations to "maintaining your strong presence" framing
- Occasional surprise congratulations for milestone events: "You've now received 100 endorsements on LinkedIn!" or "Your connection count just passed 1,000."

---

## 13. Apple Contacts Sync

### 13.1 LinkedIn URL Enrichment

After the user completes the import review and marks contacts as "Add," SAM should offer to enrich the corresponding Apple Contact records with LinkedIn profile URLs.

**Trigger:** After the Add/Later classification is complete and the user has confirmed their choices.

**Presentation:**
```
"SAM found LinkedIn profile URLs for [X] of your contacts marked as Add.
Would you like to add their LinkedIn URLs to your Apple Contacts?
This makes it easy to find their LinkedIn profile from your phone's
Contacts app.

[Add LinkedIn URLs to Apple Contacts]  [Not Now]"
```

**Scope:** Only contacts marked "Add" — not "Later" contacts.

**Implementation:**
```swift
// For each "Add" contact that matched an existing Apple Contact:
// 1. Read the Apple Contact record
// 2. Check if a LinkedIn URL already exists in socialProfiles or urlAddresses
// 3. If not present, add the LinkedIn profile URL as a social profile
//    with label "LinkedIn"
// 4. If a DIFFERENT LinkedIn URL is already present, flag for user review
//    (possible stale URL or duplicate account situation)
```

**Batch operation:** This should be a single-confirmation batch operation, not per-contact approval. The user sees a summary ("Will update 47 Apple Contacts with LinkedIn URLs") and approves once.

### 13.2 Ongoing Sync

After the initial batch, SAM should offer to automatically add LinkedIn URLs to Apple Contacts for future imports where contacts are marked "Add." This should be a preference the user can toggle:

```
Settings > Integrations > LinkedIn > "Automatically add LinkedIn URLs to Apple Contacts for new contacts marked Add"
```

---

## 14. Data Model (SwiftData)

### 14.1 Core Entities

```swift
// Represents a LinkedIn data import event
@Model
class LinkedInImport {
    var id: UUID
    var importDate: Date
    var archiveFileName: String
    var connectionCount: Int
    var newContactsFound: Int
    var touchEventsFound: Int
    var status: ImportStatus        // .processing, .awaitingReview, .complete
}

// Links a SAM contact to their LinkedIn identity
@Model
class LinkedInContactLink {
    var id: UUID
    var samContactId: UUID          // FK to SAM's main Contact entity
    var linkedInProfileUrl: String  // primary identifier
    var linkedInVanityName: String?
    var linkedInEmail: String?      // if available from export
    var currentCompany: String?
    var currentPosition: String?
    var connectedOn: Date?
    var lastUpdated: Date
    var importSource: UUID          // FK to LinkedInImport
    var triageStatus: TriageStatus  // .add, .later, .merged
    var intentionalTouchScore: Int
}

// Represents a single intentional touch event
@Model
class IntentionalTouch {
    var id: UUID
    var platform: String            // "linkedin", "facebook", etc.
    var touchType: String           // "message", "endorsement", "recommendation", etc.
    var direction: TouchDirection   // .inbound, .outbound, .mutual
    var contactProfileUrl: String?  // links to LinkedInContactLink
    var samContactId: UUID?         // resolved SAM contact (may be nil if unmatched)
    var date: Date
    var snippet: String?            // first 200 chars of content
    var weight: Int                 // touch weight score
    var source: TouchSource         // .bulkImport, .emailNotification
    var sourceImportId: UUID?       // FK to LinkedInImport if from bulk import
    var sourceEmailId: String?      // Gmail message ID if from notification
}

// Tracks which notification types SAM has seen (for setup guidance)
@Model
class NotificationTypeTracker {
    var id: UUID
    var platform: String            // "linkedin"
    var notificationType: String    // "message", "endorsement", etc.
    var lastSeenDate: Date?
    var firstSeenDate: Date?
    var totalCount: Int
    var setupTaskDismissCount: Int  // how many times user dismissed the setup task
}

// Platform-agnostic social profile snapshot
@Model
class SocialProfileSnapshot {
    var id: UUID
    var samContactId: UUID?         // nil if this is the USER's own profile
    var platform: String
    var platformUserId: String
    var platformProfileUrl: String
    var importDate: Date
    var displayName: String
    var headline: String?
    var summary: String?
    var currentCompany: String?
    var currentTitle: String?
    var industry: String?
    var location: String?
    var websites: String?           // JSON array
    var skills: String?             // JSON array
    var connectionCount: Int?
    var followerCount: Int?
    var postCount: Int?
    var platformSpecificDataJson: String?  // JSON blob for platform-specific fields
}

// Stores analysis results
@Model
class ProfileAnalysisRecord {
    var id: UUID
    var platform: String
    var analysisDate: Date
    var overallScore: Int
    var resultJson: String          // full ProfileAnalysisResult as JSON
}

// Stores engagement metrics snapshots
@Model
class EngagementSnapshot {
    var id: UUID
    var platform: String
    var periodStart: Date
    var periodEnd: Date
    var metricsJson: String         // full EngagementMetrics as JSON
    var benchmarkResultJson: String? // benchmarking agent output
}

// Enums
enum ImportStatus: String, Codable {
    case processing, awaitingReview, complete, failed
}

enum TriageStatus: String, Codable {
    case add, later, merged
}

enum TouchDirection: String, Codable {
    case inbound, outbound, mutual
}

enum TouchSource: String, Codable {
    case bulkImport, emailNotification, manual
}
```

---

## 15. Agent Definitions

### 15.1 Agent Registry

SAM uses the following AI agents for LinkedIn integration:

| Agent Name | Trigger | Input | Output | Schedule |
|-----------|---------|-------|--------|----------|
| `LinkedInProfileAnalyzer` | After bulk import + monthly | SocialProfileSnapshot + touch data + content data | ProfileAnalysisResult | On import, then monthly |
| `CrossPlatformConsistencyChecker` | After any platform import where 2+ profiles exist | Array of SocialProfileSnapshot | CrossPlatformConsistencyResult | On import of 2nd+ platform |
| `EngagementBenchmarker` | Weekly + monthly summary generation | EngagementMetrics + previous snapshots | Benchmarking assessment | Weekly (brief), Monthly (full) |
| `MessageReplyAdvisor` | When new inbound message detected | Contact context + message snippet + touch history | MessageReplySuggestion | Real-time (on email detection) |
| `NotificationSetupAdvisor` | Daily check of NotificationTypeTracker | Missing notification types + days since last check | NotificationSetupTask (or nil) | Daily |

### 15.2 Agent Execution Environment

All agents that require AI inference should:
- Use the local AI model if available and capable (for simple pattern matching, scoring)
- Escalate to cloud AI (via Anthropic API) for nuanced analysis (profile optimization, content strategy, reply suggestions)
- Cache results in the appropriate SwiftData model
- Include the previous analysis result (if any) in the prompt for continuity

### 15.3 Agent Error Handling

If an agent fails (API timeout, parsing error, insufficient data):
- Log the error with context
- Do NOT surface an error to the user unless it affects a user-initiated action
- Retry on next scheduled trigger
- If a real-time agent (MessageReplyAdvisor) fails, fall back to showing the raw notification without a suggestion

---

## Appendix A: LinkedIn Email Sender Addresses

Known LinkedIn email sender addresses as of March 2026. SAM should match on `@linkedin.com` domain broadly and update this list if new patterns are detected.

```
messages-noreply@linkedin.com      — Direct messages
invitations@linkedin.com           — Connection requests
notifications-noreply@linkedin.com — General notifications (endorsements,
                                     comments, reactions, mentions, job changes,
                                     birthdays, profile views)
inmail-hit-reply@linkedin.com      — InMail messages (Premium)
endorsements@linkedin.com          — Endorsement notifications (may be deprecated
                                     in favor of notifications-noreply)
recommendations@linkedin.com       — Recommendation notifications
news@linkedin.com                  — LinkedIn News / Pulse digest
jobs-noreply@linkedin.com          — Job alerts
campaigns-noreply@linkedin.com     — LinkedIn marketing emails
```

## Appendix B: LinkedIn Notification Settings Direct URLs

```
General notification settings:
https://www.linkedin.com/psettings/communications

Email-specific notification controls:
https://www.linkedin.com/psettings/communications/email

In-app notification controls:
https://www.linkedin.com/psettings/communications/inapp

Push notification controls:
https://www.linkedin.com/psettings/communications/push
```

## Appendix C: LinkedIn Data Export Request URL

```
Direct link to request data export:
https://www.linkedin.com/psettings/member-data

This bypasses the Settings > Data Privacy navigation entirely.
```
