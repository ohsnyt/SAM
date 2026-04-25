# Pending Uploads & Sync

When you record offline (Mac unreachable, weak Wi-Fi, or you skipped the connection), the audio sits on your iPhone in the **pending uploads queue**. SAM syncs it the next time the Mac is reachable.

## How to Use

1. On the Record tab, look below the record button for **"X recordings waiting to sync"** — tap it to open the **Pending Recordings** sheet.
2. Each row shows the recording date, duration, file size, and status (Waiting / Uploading / Processing / Failed).
3. **Swipe left** on any row to delete a recording you no longer want synced.
4. Close the sheet with **Done** in the top-right.

## Statuses

- **Waiting** (gray) — sitting in the queue, not yet uploading
- **Uploading** (blue) — actively transferring chunks to the Mac
- **Processing** (orange) — the Mac is transcribing and summarizing
- **Failed** (red) — upload couldn't complete; reason shown below the row
- **Done** (green) — synced; row is removed from the list

## How Sync Triggers

Sync starts automatically when:

- The iPhone establishes a connection to the Mac (same Wi-Fi, both apps open).
- You return to the Record tab with pending items in the queue.
- Network conditions improve after a previous failure.

There is no manual "Sync Now" button — SAM handles it whenever the Mac is reachable.

## Tips

- **Deleted recordings cannot be recovered.** If the queue says Failed and you don't want to retry, swipe to delete.
- Failures often clear themselves — if both devices are on the same Wi-Fi and SAM is open on the Mac, the next attempt usually succeeds.
- Large recordings sync in chunks, so progress is shown as a percentage during Uploading.
- The **attempt count** below each row shows how many retries SAM has made — recurring failures may indicate a stuck queue worth deleting.

---

## See Also

- **Live vs Offline Recording** — when offline mode kicks in
- **Recording Meetings on iPhone** — the full recording flow
- **Pairing Your Mac via iCloud** — confirm both devices are paired
