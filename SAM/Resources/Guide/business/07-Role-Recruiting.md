# Role Recruiting

Discover and cultivate candidates for any role — board members, referral partners, volunteer positions, or team recruits — by letting SAM scan your entire contact network.

## How It Works

Role Recruiting uses a two-pass process to find the best candidates in your network:

1. **Swift Pre-Filter** — SAM quickly narrows your contacts to the top 25 most relevant people based on job titles, relationship themes, interaction history, and notes. This step is instant.

2. **AI Deep Analysis** — Each pre-filtered contact is individually evaluated by the on-device AI model against your role criteria. The AI reads relationship summaries, evidence snippets, and themes to produce a match score (0–100%), rationale, strength signals, and gap signals.

## Why Scanning Takes Time

The AI analysis is thorough — it evaluates each candidate individually using your Mac's GPU for on-device inference. This ensures privacy (no data leaves your Mac) but means each scan takes roughly **five minutes** once SAM finishes any other background work that may already be running (coaching, briefings, strategy analysis). If SAM's AI is idle when you start the scan, it begins immediately.

**You don't need to wait.** After clicking "Scan Contacts," the process runs in the background. You can watch progress in the sidebar minion list from anywhere in SAM, and you'll receive a system notification when it's done. Come back to the Roles tab to review results.

## Creating a Role

1. Go to **Business → Roles** and click **New Role**
2. Fill in the role name (e.g., "ABT Board Member"), description, and target count
3. Add **Key Qualities** — the criteria SAM uses to score candidates (e.g., "Community leadership experience", "5+ years in the network")
4. Optionally add **Disqualifying Conditions** — people matching these are automatically excluded (e.g., "Employees of ABT", "Anyone compensated by the organization")
5. Click **Save**

The more specific your criteria, the better SAM's scoring. You can always edit criteria later as you learn what makes a good candidate.

## Scanning for Candidates

Click **Scan Contacts** to start the AI analysis. The progress bar shows which contact is being evaluated. When complete, a **Review Suggestions** button appears with the number of matches found.

## Reviewing Suggestions

The review sheet shows candidates ranked by match score. For each person you'll see:

- **Match score** — color-coded: green (70%+), orange (50–69%), gray (below 50%)
- **Strength signals** — what makes this person a good fit
- **Gap signals** — potential concerns or missing qualifications
- **Match rationale** — the AI's 2–3 sentence explanation

For each candidate, you can:
- **Add to Pipeline** — moves them into the Suggested stage for cultivation
- **Pass** — optionally provide a reason (e.g., "too busy," "wrong geography"), which teaches SAM to make better suggestions next time

## The Candidate Pipeline

Once approved, candidates move through five stages:

| Stage | Meaning |
|-------|---------|
| **Suggested** | SAM identified, you've approved |
| **Considering** | Actively evaluating this person |
| **Approached** | You've reached out about the role |
| **Committed** | Person has agreed to fill the role |
| **Passed** | Declined or disqualified |

## Exclusion Criteria

Disqualifying conditions prevent conflicts of interest. For example, if you're recruiting board members for a nonprofit, employees of that organization may be ineligible. Add these conditions in the role editor and SAM will instruct the AI to score them at 0%.

## Refinement Over Time

Every time you pass on a candidate with a reason, SAM feeds that feedback into future scans. Over time, your "rejection reasons" accumulate and the AI learns to avoid suggesting similar people. This makes each scan more targeted than the last.

## Handoff to Other Pipelines

For roles that map to existing pipelines (e.g., "Agent" maps to the WFG recruiting pipeline), candidates who reach the "Committed" stage are automatically handed off — the appropriate role badge is added and a recruiting stage record is created.

---

## See Also

- **Recruiting Pipeline** — The 7-stage WFG pipeline that takes over after role recruiting handoff
- **Goals** — Create a "Role Filling" goal to track your recruiting progress
- **Strategic Insights** — Role recruiting data feeds into SAM's business intelligence for content suggestions and strategic recommendations
