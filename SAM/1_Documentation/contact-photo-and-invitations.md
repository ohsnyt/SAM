# Contact Photo Management & Rich Invitations

Two related cross-app integrations: photo capture/write-back into Apple Contacts, and rich-text invitation drafting → Mail.app handoff → sent-mail detection.

## Contact Photo Management

### Drop / Paste → Resize → Write to Apple Contacts

Flow: `PersonDetailView` (drop target + paste handler) → `ContactPhotoCoordinator` (orchestration) → `ContactPhotoService` actor (CNContactStore write).

`ImageResizeUtility` center-crops to square, resizes to 600×600 max, compresses to JPEG (0.85 quality).

### Safari Profile Opener

`SafariBrowserHelper` uses AppleScript to open LinkedIn / Facebook profiles in a sized, positioned Safari window for photo dragging. Tracks window IDs and closes them after a successful drop. Requires `com.apple.Safari` in `temporary-exception.apple-events` entitlement.

### Profile URL Resolution

Checks in order:
1. `SamPerson.linkedInProfileURL` / `facebookProfileURL`
2. Apple Contacts `socialProfiles`
3. Apple Contacts `urlAddresses`

`sanitizeProfileURL()` strips service prefixes (e.g., `linkedin:www.linkedin.com/...`) that Apple Contacts sometimes includes. Falls back to a Facebook people search for confirmed friends without a stored profile URL.

### LinkedIn PDF Import

Drag a LinkedIn-generated profile PDF onto the "Add a note..." bar in `PersonDetailView`. `LinkedInPDFParserService` (deterministic, no AI) extracts structured data and creates `PendingEnrichment` records for email, phone, company, job title, and LinkedIn URL. The note it generates triggers AI analysis for family / relationship discovery.

## Rich Invitation System

Hybrid model: rich text editor in SAM → Mail.app handoff → sent-mail detection.

### Drafting

- `RichInvitationEditor` (NSTextView) supports bold, italic, links (⌘B / ⌘I / ⌘K), inline images, QR codes
- `LinkInsertionPopover` offers event-join URL presets, the user website, custom URLs, and optional QR codes

### HTML Handoff

`AttributedStringToHTML` converts the rich text to HTML. `ComposeService.composeHTMLEmail()` opens Mail.app via AppleScript `html content`.

### Sent-Mail Detection

`SentMailDetectionService` watches `NSWorkspace` focus events. When SAM regains focus after Mail.app, it scans the Envelope Index for recently sent messages matching pending watch subjects. Retry pattern: 1s, 3s, 8s, 15s, 30s.

### Recipient Intelligence

- TO = invitee
- BCC = informational
- CC with Agent / Vendor / Referral = informational
- CC with Client / Lead = ambiguous → prompts user via `InvitationRecipientReviewSheet`

### Lifecycle

Participation status moves: `notInvited` → `draftReady` → `handedOff` (at Mail.app open) → `invited` (when sent mail confirmed).
