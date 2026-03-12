# Clipboard Capture

Copy a conversation from any messaging app and save it as relationship evidence in SAM. This is the fastest way to capture conversations that happen outside of email and calendar.

## How to Activate

Two ways to start clipboard capture:

| Method | How | Requires |
|--------|-----|----------|
| **Global hotkey** | Press **⌃⇧V** from any app | Accessibility permission |
| **Menu command** | Edit > Capture Clipboard Conversation | Nothing extra |

The global hotkey works even when SAM isn't the frontmost app — copy a conversation in Messages, press ⌃⇧V, and SAM opens the capture window immediately.

## Step by Step

### 1. Copy the Conversation

Select and copy a conversation from Messages, WhatsApp, Slack, or any messaging app.

### 2. Capture

Press **⌃⇧V** or use the menu command. SAM opens a capture window and begins analyzing the clipboard.

### 3. Review Participants

SAM parses the conversation, detects platform and message structure, and shows:

- **Title** — Auto-generated (e.g., "iMessage with Sarah Chen"), editable
- **Date** — Defaults to the conversation date, editable
- **Senders** — Each unique sender with auto-match status:

| Status | Meaning |
|--------|---------|
| "Me (auto)" | SAM identified this as you |
| Name + role badge | Matched to an existing SAM contact |
| Orange "?" | Unmatched — use the search field to link to a contact |

For unmatched senders, type in the search field to find and link the right person. SAM searches your contacts as you type.

### 4. Save

Click **Save as Evidence** (⌘Return) when at least one non-"Me" sender is matched. SAM:

- Groups messages by matched person
- Analyzes each conversation on-device for topics, action items, and sentiment
- Creates evidence entries linked to each person
- Discards the raw conversation text — only AI summaries are stored

## Error Recovery

If parsing fails (unusual format, empty clipboard, etc.), SAM offers:

- **Try Again** — Re-attempt parsing
- **Save as Note** — Falls back to saving the clipboard text as a manual note
- **Cancel** — Close without saving

## Setup

Enable the global hotkey in **Settings > General > Clipboard Capture**. The hotkey requires Accessibility permission:

1. Open **System Settings > Privacy & Security > Accessibility**
2. Enable SAM in the list
3. The status indicator in Settings shows "Authorized" when granted

The menu command (Edit > Capture Clipboard Conversation) works without any extra permissions.

## Privacy

SAM analyzes conversation text on-device, then discards the raw content. Only AI-generated summaries and metadata (participants, date, platform) are stored. No conversation text leaves your Mac.

## Tips

- Use clipboard capture for any conversation that contains commitments, next steps, or relationship context
- It works with any messaging format SAM can parse — iMessage, WhatsApp, SMS, and more
- The global hotkey is the fastest path: copy, ⌃⇧V, confirm senders, save

---

## See Also

- **Voice Dictation** — Hands-free note capture using on-device speech recognition
- **Adding Notes** — Capture meeting notes and observations directly on a person's profile
- **Privacy and On-Device AI** — How SAM analyzes then discards raw conversation text
