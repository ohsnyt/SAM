# Social Imports

Import your social network connections to find warm leads already in your contacts, enrich existing profiles, and discover new opportunities.

## Supported Platforms

### LinkedIn

1. Download your data export from LinkedIn (Settings > Get a copy of your data)
2. Go to **File > Import > LinkedIn** and select the ZIP file
3. SAM parses your connections, messages, and activity
4. A review sheet shows:
   - **Exact matches** — Automatically linked to existing SAM contacts (green checkmark)
   - **Probable matches** — SAM's best guess; confirm or reject each one
   - **New contacts** — People not in your network yet; choose "Add" or skip
5. Confirm the import

After import, SAM stores interaction history as scored touch events and optionally syncs LinkedIn profile URLs back to Apple Contacts.

### Substack

Substack has two import tracks:

**Publication Feed** — Enter your Substack domain (e.g., "yourname.substack.com") and SAM fetches your post history via RSS. Used for content strategy analysis and writing voice extraction.

**Subscriber CSV** — Download your subscriber list from Substack Settings > Exports, then import the CSV. SAM shows a preview with subscriber count, matches to existing contacts, new leads, and paid subscription status. Confirm to import.

### Facebook

1. Download your Facebook data export (Settings > Download Your Information)
2. Go to **File > Import > Facebook** and select the ZIP file
3. SAM extracts your friends list, messages, comments, and reactions
4. Review matches and confirm the import

## What SAM Does With Imported Data

For each platform, SAM:

- **Matches contacts** against your existing Apple Contacts and SAM people
- **Creates enrichment candidates** — Updated emails, phone numbers, job titles flagged for your review
- **Extracts your writing voice** — Analyzes your posts to match content draft tone
- **Generates profile analysis** — Scores your social presence with improvement suggestions (visible in Grow > Profile tab)
- **Records touch events** — Social interactions scored for relationship signal strength

## Configuring Imports

Import settings are in **Settings > Data Sources** under each platform's disclosure group. Each shows:

- Last import date and count
- Auto-sync toggles (e.g., "Automatically add LinkedIn URLs to Apple Contacts")
- Re-analyze button for fresh profile analysis

## Privacy

All matching and analysis happens entirely on-device. Your social data never leaves your Mac. SAM analyzes imported content, extracts insights, and discards raw text — only summaries and metadata are stored.

---

## See Also

- **Lead Acquisition** — The Grow dashboard where imported social data powers profile analysis and lead discovery
- **Contact List** — Where matched and newly added contacts appear after a social import
- **Settings and Permissions** — Configure import settings and auto-sync options for each platform
