# Privacy and On-Device AI

SAM is designed from the ground up to keep your data private. Every piece of intelligence — relationship coaching, business analysis, content drafts, meeting prep — is generated on your Mac using Apple's on-device AI models.

## On-Device Processing

SAM uses **Apple Foundation Models** for all AI tasks. These models run locally on your Mac's Neural Engine and never send data to external servers.

This means:

- **No cloud AI** — Your notes, emails, conversations, and business data never leave your Mac
- **No telemetry** — SAM doesn't track usage, send analytics, or report to any external service
- **No API keys** — There's nothing to configure or pay for; AI works immediately
- **Works offline** — All AI features function without an internet connection

## How SAM Handles Your Data

### What SAM Reads

SAM accesses data from Apple system apps you've granted permission for:

| Source | What SAM Reads | What SAM Stores |
|--------|---------------|----------------|
| **Contacts** | Names, emails, phones, organization | Linked profile in SAM database |
| **Calendar** | Event titles, times, attendees, locations | Event metadata + time categorization |
| **Mail** | Message headers and bodies from designated accounts | Envelope metadata + AI summaries only |
| **Messages** | Conversation text (via security-scoped bookmark) | AI summaries only — raw text discarded |
| **Calls** | Call records (duration, direction, timestamp) | Metadata only |

### The Analyze-Then-Discard Pattern

For sensitive content like email bodies and message text, SAM follows a strict pattern:

1. **Read** the raw content from the system source
2. **Analyze** on-device using AI (extract action items, topics, sentiment, relationships)
3. **Store** only the AI-generated summary and metadata
4. **Discard** the raw content — it's never written to SAM's database

This means SAM's intelligence comes from understanding your communications, but the actual text of your emails and messages is never permanently stored.

## Data Storage

SAM stores its data locally using Apple's SwiftData framework:

- **Database location** — Your Mac's application support directory
- **No cloud sync** — Data stays on this Mac only
- **Undo history** — Up to 30 days of undo history for destructive or relational changes
- **Backups** — Follow your normal Mac backup strategy (Time Machine, etc.)

## Account Scoping

SAM only accesses accounts you explicitly designate:

- **Mail** — Only email accounts you select in Settings > Data Sources > Mail
- **Calendar** — Only calendars you select in Settings > Data Sources > Calendar
- **Contacts** — Only the contact group you designate in Settings > Data Sources > Contacts (SAM reads all contacts for matching, but only imports from your chosen group)

## Social Import Privacy

When you import data from LinkedIn, Facebook, or Substack:

- The export files are read locally and never uploaded anywhere
- SAM extracts insights (matches, profiles, writing voice) and discards raw data
- All matching happens on-device by comparing against your existing contacts
- Imported interaction history is stored as scored touch events, not raw messages

## Compliance Scanning

SAM scans outgoing drafts for compliance-sensitive language entirely on-device. Flagged content is shown to you for review — it's never reported externally. Compliance settings are configurable in Settings > Business > Compliance.

## What SAM Never Does

- Sends data to any external server or API
- Shares your information with Anthropic, Apple, or any third party
- Stores raw email or message text beyond the analysis session
- Accesses accounts or data sources you haven't explicitly authorized
- Writes to external systems (Contacts, Calendar) without your explicit approval

---

## See Also

- **Settings and Permissions** — Configure which data sources SAM can access and manage permissions
- **Clipboard Capture** — How SAM handles captured conversation text with the analyze-then-discard pattern
