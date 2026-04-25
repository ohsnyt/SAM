# Briefing Sync to iPhone

Your morning briefing is generated on the Mac and pushed to iPhone through your iCloud private database. SAM Field reads it on launch and every time you pull-to-refresh, so the same narrative you see on the Mac is available in the field.

## How to Use

1. Open SAM on your Mac and let the daily briefing generate (look for the "Morning Briefing" section on Today).
2. Open SAM Field on iPhone and go to the **Today** tab.
3. Pull down to trigger a refresh — SAM Field fetches the latest briefing from CloudKit.
4. The briefing appears at the top with a "1 min ago" / "12 min ago" timestamp.

## What Syncs

- **Narrative summary** — the AI-written morning paragraph
- **Section heading** — usually "Morning Briefing" or, on Mondays, "This Week's Priorities"
- **Generation timestamp** — used to show how fresh the briefing is
- **Workspace settings** — calendar selection, work hours, contact group (so calendar matching works on the phone too)

## Tips

- If no briefing appears, check that you've opened SAM on your Mac at least once today — generation happens there.
- Both devices must be signed in to the same iCloud account; CloudKit's private database is what scopes the sync.
- iCloud sync runs over cellular too — you don't need to be on Wi-Fi for the briefing to land.
- Priority actions and follow-up cards are intentionally not surfaced on iPhone yet (they require channels — call, text, email — that aren't wired up). Triage them on the Mac.

---

## See Also

- **Today on iPhone** — what else lives on the Today tab
- **Daily Briefing** (Mac) — how the briefing is generated
- **Pairing Your Mac via iCloud** — how device trust is established
