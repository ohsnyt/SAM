# Live vs Offline Recording

SAM Field records the same way no matter what — but where the audio goes and how fast you see a summary depends on whether your Mac is reachable.

## Live Mode (Mac Connected)

When SAM Field finds your Mac on the local network:

- Audio **streams in real time** to the Mac over an encrypted TCP connection.
- The Mac transcribes and summarizes as you go; the summary lands on your phone seconds after you tap Stop.
- "Change Recording Type" is available right after Stop while the Mac still has the verbatim transcript.

## Offline Mode (Mac Unreachable)

When the Mac isn't on the same Wi-Fi (or is closed):

- Audio is recorded **locally to the iPhone** as a WAV file.
- A "Recording locally" banner appears so you know the Mac isn't in the loop.
- After Stop, the recording joins the **pending uploads queue** (see "Pending Uploads & Sync").
- When the iPhone next sees the Mac, queued recordings sync automatically and the Mac generates summaries from there.

## How to Use

1. Start recording the same way in both modes — there's nothing to switch.
2. Watch the **connection pill** above the participant list:
   - "Searching for Mac…" with a spinner = trying to connect
   - Empty = connected and live
   - "Recording locally" banner = offline mode
3. If SAM can't find the Mac after a brief wait, you'll see a **Can't find your Mac** alert with **Retry**, **Record Locally**, or **Cancel**.

## Tips

- Both devices must be on the same Wi-Fi network for live mode. Cellular-only setups always use offline mode.
- Offline recordings show up in the **Pending Recordings** sheet (tap the "X recordings waiting to sync" banner under the record button).
- Reclassification (changing the recording type after the fact) only works in live mode while the Mac still holds the verbatim transcript.

---

## See Also

- **Recording Meetings on iPhone** — the full recording flow
- **Pending Uploads & Sync** — what happens to offline recordings
- **Pairing Your Mac via iCloud** — how SAM Field finds your Mac in the first place
