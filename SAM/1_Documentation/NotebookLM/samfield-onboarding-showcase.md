# SAM Field Onboarding & Help Showcase

## Introduction

SAM Field is the iPhone companion to SAM on the Mac -- not a standalone app. Install it from the App Store, sign in to the same iCloud account as your Mac, and you're ready to record meetings, track mileage, and read the morning briefing on the go. There is no setup wizard, no account to create, and no pairing code to type.

## First Launch

When you open SAM Field for the first time, the Today tab is selected by default. Three tabs sit at the bottom: **Today**, **Record**, and **Trips**. There is no separate Settings tab -- a gear icon in the upper-right of Today opens Settings as a sheet.

What you see on first launch of each tab:

- **Today** -- A list with an "Enable Calendar Access" prompt at the top, an empty schedule section, and a quick-stats row at the bottom. A discovery tip introduces the pull-to-refresh gesture for syncing the briefing from your Mac.
- **Record** -- A capture-ready screen showing connection status to your Mac. Tap to record; if the Mac is reachable on the local network you'll get live transcription, otherwise the recording queues for later sync.
- **Trips** -- An empty trip history with a "Start Trip" button. The first time you open it, a tip explains that stops are detected automatically by GPS and dwell time.
- **Settings (sheet)** -- Opened from the gear icon. Shows the pairing list, trip preferences, and About info.

## Pairing

Pairing is automatic via iCloud -- no QR code, no PIN, nothing to type. When you open SAM on your Mac, it writes a pairing token to your iCloud private database. When SAM Field launches under the same Apple ID, it reads that token from CloudKit and silently adopts the Mac as a trusted partner. Different iCloud accounts cannot read the token.

In Settings, the **Mac Connection** section shows every paired Mac with its display name and pairing date. A **Refresh from iCloud** button forces an immediate CloudKit pull -- useful right after first installing SAM on a new Mac, since the token may not have replicated yet. Each Mac in the list has a minus button that unpairs it locally.

## Permissions Priming

SAM Field requests system permissions at the moment each feature is first used, never up front in a bulk wizard:

- **Location** -- Asked when you tap Start Trip; Always-or-While-Using is required for IRS-compliant trip logging.
- **Motion** -- Used to detect dwell at stops.
- **Microphone** -- Asked the first time you tap Record.
- **Contacts** -- Requested when a trip stop suggests a nearby contact; only used for profile photos and names.
- **Calendar** -- Asked from Today when you tap "Enable Calendar Access" to populate today's schedule and pre-populate participants for recordings.

Before each system prompt, a TipKit tip explains *why* the permission is needed, so the user understands the value before tapping Allow.

## TipKit System

SAM Field uses Apple's TipKit framework for in-app guidance. The catalog currently ships sixteen tips spread across the three tabs and Settings. Each tip renders with a thin-material card, an orange circular icon, a title, a one-sentence message, and a "Learn more" action.

Example tip titles:

- **"Daily Briefing"** -- Today; explains pull-to-refresh syncing from the Mac.
- **"Capture a Meeting"** -- Record; explains live vs. offline modes.
- **"Stops Are Automatic"** -- Trips; explains GPS-based dwell detection.
- **"Automatic Mac Pairing"** -- Settings; explains the iCloud trust model.

Tips are gated by donated events (`openedTodayTab`, `firstRecordingCompleted`, `firstTripCompleted`) so they appear at the right moment instead of all at once. A global toggle in `FieldTipState` disables guidance entirely, and "Reset All Tips" wipes the TipKit datastore so every tip becomes eligible again.

## In-Settings Help

Each tip's "Learn more" action is wired to a guide article ID -- the same shared catalog the Mac uses, with thirteen articles tagged for iOS. The mapping is in place, but a dedicated guide reader is not yet built into SAM Field; tapping "Learn more" today does not navigate. The plan is to add an in-Settings help section that loads the iOS-flagged articles directly from the shared manifest.

## Per-Tab Discovery

Each tab teaches itself the first time you visit. **Today** shows a briefing-sync tip up top and a quick-stats tip below. **Record** shows a start-recording tip plus a live/offline badge tip; after your first completed recording, follow-ups appear for reclassifying the recording type, swipe-to-delete, and the Looks Good approval flow. **Trips** shows a start-trip tip immediately, then unlocks swipe-to-delete, export-for-taxes, and a period-filter tip after the first completed trip. **Settings** shows the pairing tip the first time you open it.

## Offline Behavior

SAM Field stays useful when the Mac is unreachable. **Recording** switches to offline mode automatically -- audio captures locally, queues in pending uploads, and syncs the next time the Mac is on the same network. **Trips** track entirely on-device; GPS, stops, and totals work without any Mac connection. **Today** keeps showing the last-cached briefing from CloudKit, with pull-to-refresh trying again when connectivity returns. The phone never depends on the Mac being online to remain functional in the field.

## Privacy

SAM Field carries the same privacy posture as the Mac. There is no cloud AI -- on-device frameworks handle anything that runs on the phone, and the rest is processed by the user's own Mac. Audio either stays on the phone (offline mode) or streams over the local network to the user's Mac (live mode); it never reaches Anthropic, OpenAI, or any third party. The pairing token in CloudKit is the only data SAM Field stores in iCloud, and it lives in the private database under the user's own Apple ID.
