# Settings and Permissions

SAM integrates deeply with Apple system apps and on-device AI. This guide explains what permissions SAM needs, how to configure data sources, and where to find key settings.

## Permissions (Settings > Permissions)

SAM requests permissions as needed, but you can review and manage them all in one place.

| Permission | What It Enables | Required? |
|-----------|----------------|-----------|
| **Contacts** | Import people from Apple Contacts, link profiles, write back enrichment data | Yes — core functionality |
| **Calendar** | Read meetings for briefings, meeting prep, time analysis, and follow-up prompts | Yes — core functionality |
| **Mail** | Scan designated work email accounts for interaction history and context | Recommended |
| **Microphone** | Voice dictation for hands-free note capture | Optional |
| **Speech Recognition** | On-device transcription of dictated audio | Optional (needed for dictation) |
| **Notifications** | Alerts for meeting prep, follow-up prompts, and evening recaps | Recommended |
| **Accessibility** | Global hotkey (⌃⇧V) for clipboard capture from any app | Optional |

### iMessage and Call History

iMessage and call history access requires granting SAM a **security-scoped bookmark** to the Messages database and call history database. Configure this in Settings > Data Sources > Communications.

### Checking Permission Status

Each permission in Settings > Permissions shows a status badge:

- **Green checkmark** — Authorized and working
- **Orange X** — Not granted or not configured
- **"Request Access" / "Open System Settings"** buttons to grant from the settings panel

## Data Sources (Settings > Data Sources)

Configure which data SAM imports and how far back it looks.

### Global History Lookback

A dropdown controls how far back SAM looks when importing calendar, mail, and communication history: **14, 30, 60, 90, 180 days, or All**. Default is 30 days. Setting "All" scans your complete history on first import.

### Contacts

- **Contact group** — Choose which Apple Contacts group SAM manages. SAM reads all contacts for matching but only imports from this group.
- **Auto-import** — Toggle automatic syncing when contacts change

### Calendar

- **Calendar selection** — Choose which calendars SAM scans
- **Event categorization** — SAM auto-categorizes events (client meetings, prep, vendor calls, recruiting, admin) for time analysis

### Mail

- **Account selection** — Choose which email accounts SAM analyzes (limit to work accounts)
- **Privacy note** — SAM analyzes message bodies on-device, then discards raw text. Only summaries are stored.

### Communications

- **Bookmark access** — Grant SAM access to the Messages and Call History databases
- **Privacy note** — Message text is analyzed then discarded. Only metadata and AI summaries are stored.

## AI and Coaching (Settings > AI & Coaching)

### Intelligence

- Model availability status
- Custom prompt editing for specialist analysts
- Advanced reasoning toggle

### Coaching

- Encouragement style preference
- Life event detection sensitivity
- Outcome type emphasis
- **"What SAM Has Learned"** — Review SAM's calibration data: which outcome types you prefer, your active hours, strategic weights, and muted types. See the **How Coaching Works** guide for details.

### Briefings

- Daily briefing timing
- Which sections to include in briefings

## Guidance and Tips (Settings > General)

| Setting | What It Controls |
|---------|-----------------|
| **Show contextual tips** | TipKit tips that appear near features during your first days |
| **Feature adoption coaching** | Progressive suggestions for features you haven't tried yet |
| **Show help buttons** | The "?" buttons in toolbars that link to guide articles |
| **Reset All Tips** | Re-show all tips as if you're seeing the app for the first time |
| **Open SAM Guide** | Opens this guide to the Getting Started section |

## Business (Settings > Business)

- **Business Profile** — Company name, focus area, team size
- **Compliance** — Compliance mode (strict/moderate/permissive), flagged phrase categories, custom rules, audit trail

---

## See Also

- **Privacy and On-Device AI** — How SAM keeps all data on your Mac and never sends it externally
- **How Coaching Works** — How SAM's adaptive learning uses your preferences from Settings
- **Social Imports** — Configure social platform data sources and import connections
