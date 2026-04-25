# Pairing Your Mac via iCloud

SAM Field automatically trusts every Mac running SAM under the same iCloud account — there is no PIN to type, no QR code to scan. Pairing tokens are distributed through your iCloud private database, so a different iCloud account literally can't read them.

## How to Use

1. Make sure both devices are signed in to the **same iCloud account**.
2. Open SAM on your Mac at least once — that publishes the pairing token to your iCloud private database.
3. Open SAM Field on iPhone and tap **Settings** (gear icon, top-right of Today).
4. The **Mac Connection** section lists every paired Mac. If it's empty, tap **Refresh from iCloud**.
5. Once a Mac appears, recording, briefing sync, and pending-upload sync all work automatically.

## What You See

- **Paired Macs** — display name and the date pairing was established.
- **Refresh from iCloud** — manually re-fetches the token list (useful after adding a new Mac).
- **Unpair** (red minus button) — removes a Mac from the local list. Note: the token still exists in iCloud, so the Mac will reappear on the next refresh unless you reset the token from the Mac side.

## Tips

- Pairing tokens are cached in the iPhone's **Keychain** so SAM Field works offline once you've fetched at least once.
- **Different iCloud accounts** can't pair — that's the whole security model. Sharing a Mac with someone on a different Apple ID won't expose your data.
- To **fully revoke** a Mac (e.g., one you no longer own), use **Reset Pairing Token** on the Mac itself — that invalidates the token in iCloud so no phone can rejoin.
- Recording over the network requires both devices on the **same Wi-Fi**, but pairing itself works over any internet connection.

---

## See Also

- **Live vs Offline Recording** — what happens when the Mac isn't reachable
- **Briefing Sync to iPhone** — uses the same iCloud private database
- **Privacy and On-Device AI** — the broader privacy posture for both platforms
