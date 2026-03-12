# How Coaching Works

SAM's coaching engine learns from your behavior to deliver better recommendations over time. This guide explains how outcomes are generated, how SAM adapts, and how you can tune the system.

## Outcome Generation

SAM generates coaching outcomes by scanning your data through 16 specialized detectors:

| Detector | What It Looks For | Outcome Type |
|----------|------------------|-------------|
| Upcoming meetings | Meetings in the next 48 hours | Preparation |
| Meetings without notes | Past meetings where you haven't captured takeaways | Follow-Up |
| Relationship decay | People whose interaction velocity is declining | Outreach |
| Pending action items | Commitments from your notes that need follow-through | Follow-Up / Proposal |
| Pipeline stalls | People stuck too long at a pipeline stage | Growth |
| Business goals | Goal pacing that needs acceleration | Growth |
| Content opportunities | Topics worth posting about based on recent interactions | Content |
| Life events | Birthdays, anniversaries, milestones to acknowledge | Outreach |
| Role suggestions | Deduced roles from contact matching that need confirmation | Review |
| Stale contacts | People inactive for 90+ days who may need archiving | Review |
| Feature adoption | Features you haven't tried yet (first 7 days) | Setup |

Each outcome is scored using a priority formula that combines urgency, relevance, and your personal calibration weights.

## Outcome Types

| Type | Color | Best For |
|------|-------|---------|
| **Preparation** | Blue | Getting ready for upcoming meetings |
| **Follow-Up** | Orange | Acting on post-meeting commitments |
| **Proposal** | Purple | Building and sending proposals |
| **Outreach** | Teal | Reaching out to cold or cooling contacts |
| **Growth** | Green | Prospecting, networking, business development |
| **Training** | Indigo | Learning and development activities |
| **Compliance** | Red | Regulatory or compliance-related actions |
| **Content** | Mint | Social media and educational content creation |
| **Setup** | Cyan | Platform configuration and feature onboarding |

## How SAM Learns

Every time you interact with an outcome, SAM records a signal:

- **Done** — SAM records when you completed it, how quickly, and on what day/hour
- **Skip** — SAM records that you passed on this type of suggestion
- **Rate** (1–5 stars) — SAM records how helpful you found it
- **Mute** — SAM permanently stops suggesting this outcome type

These signals accumulate in the **Calibration Ledger**, which adjusts future outcomes:

### Preference Learning

SAM computes an **act rate** for each outcome type — the percentage you complete vs. skip. Types with low act rates get progressively lower priority. Types you consistently act on get boosted.

### Timing Patterns

SAM tracks which hours and days you're most productive. It identifies your **peak hours** (top 3) and **most active days** (top 2) to influence when time-sensitive outcomes surface.

### Response Speed

SAM notices how quickly you respond to different outcome types. Fast responders see more time-urgent outcomes; if you typically take longer, SAM adjusts urgency weights accordingly.

### Encouragement Style

SAM adapts its tone when you complete outcomes:

| Style | Example |
|-------|---------|
| **Direct** | "Done. Sarah's follow-up is handled." |
| **Supportive** | "Great follow-through. That consistency builds trust." |
| **Achievement** | "That's 5 outcomes completed. Impressive track record." |
| **Analytical** | "Completed in your typical timeframe (~15 min avg). Efficient." |

By default, SAM learns which style you respond to best. You can also set a preference in Settings > AI & Coaching.

### Data Decay

After 90 days without updates, SAM automatically halves old counters so recent behavior dominates over outdated patterns.

## What SAM Has Learned

Open **Settings > AI & Coaching > Coaching** to see the "What SAM Has Learned" section:

- **Overview** — Total outcomes completed, skipped, and your average rating
- **Outcome preferences** — Act rate per type, shown as a progress bar (green = you love it, orange = you often skip it)
- **Your active hours** — Peak hours and most active days
- **Strategic focus** — Category weights (pipeline, time, patterns) adjusted from your feedback
- **Muted types** — Outcome types you've permanently suppressed, with unmute buttons

## Resetting

You can reset individual elements or everything at once:

- **Reset a specific type** — Clear learning for one outcome type
- **Reset timing data** — Clear hour/day tracking
- **Reset strategic weights** — Return category emphasis to defaults
- **Unmute a type** — Re-enable a previously muted outcome type
- **Reset All Learning** — Start fresh with no calibration data

## How Calibration Affects AI

SAM generates a calibration summary that's injected into AI system instructions for all coaching tasks. This means every AI-generated recommendation is personalized based on what you've taught SAM about your preferences, schedule, and priorities.

## Tips

- Don't worry about "training" SAM perfectly — just use it naturally and it adapts
- If you're getting too many of one type, right-click Skip and choose "Stop suggesting" to mute it
- Check "What SAM Has Learned" after a few weeks to see if the calibration matches your expectations
- Rating outcomes (even occasionally) significantly improves recommendation quality

---

## See Also

- **Outcome Queue** — Where coaching outcomes appear and how to work through them
- **Settings and Permissions** — Access coaching preferences, calibration data, and specialist prompts
- **Daily Briefing** — How coaching recommendations surface in your morning briefing
