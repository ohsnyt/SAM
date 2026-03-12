# Strategic Insights

Strategic Insights is SAM's business intelligence layer. It synthesizes data from across your practice — pipeline, production, time allocation, interactions — into actionable recommendations and projections.

## How It Works

SAM runs multiple specialist analysts in the background, each focused on a specific area:

| Analyst | What It Examines |
|---------|-----------------|
| **Pipeline Analyst** | Funnel health, conversion rates, stall detection |
| **Time Analyst** | Calendar categories, time allocation vs. ideal balance |
| **Pattern Detector** | Interaction patterns, meeting quality, behavioral correlations |
| **Content Advisor** | Topics for social content based on recent client interactions |

Results are synthesized by the Strategic Coordinator and presented in six sections.

## Sections

### Scenario Projections

Business outcome scenarios based on your current pace: "At current prospecting pace, expect approximately X new clients in 6 months." Projections include confidence ranges and are clearly labeled as estimates.

### Strategic Actions

Specific, high-impact recommendations. Each shows:

- **Priority dot** — Red (urgent), orange (important), green (when possible)
- **Category badge** — Pipeline, time, pattern, or content
- **Title and rationale** — What to do and why it matters
- **Action buttons** — "Act" to get an implementation plan, "Dismiss" to pass

When you click **Act**, SAM develops a coaching plan with step-by-step guidance. Click **View Plan** to open the coaching session.

### Pipeline Health

A narrative summary of your combined pipeline status — client funnel velocity, recruiting progress, and any concerning trends.

### Time Balance

Analysis of how you actually spend your time vs. how you should. Sourced from calendar event categorization and evidence timestamps. Flags imbalances like too much admin time vs. client-facing activity.

### Patterns

Correlations SAM has detected that you might not see yourself:

- "Clients referred by existing clients convert 3x faster"
- "Tuesday afternoon meetings produce 40% more follow-through"
- "Agents who attend 3+ training sessions in month one have 70% licensing success"

### Content Ideas

Topic suggestions for social media content, each with key discussion points. Click any topic to open the **Content Draft Sheet** and generate a platform-specific post.

## Refreshing

Click **Refresh** to regenerate analysis from your latest data. The timestamp shows when analysis was last run. Strategic analysis uses background priority and may take a few seconds.

## Acting on Recommendations

The full flow for acting on a strategic recommendation:

1. Review the recommendation's title and rationale
2. Click **Act** to open the feedback sheet
3. Provide any context or preferences for the approach
4. SAM generates an implementation plan with coaching support
5. Click **View Plan** to work through the steps

Your feedback (act vs. dismiss) is tracked and feeds back into SAM's learning — future recommendations adapt to what you find most valuable.

## Important Notes

- All projections are clearly labeled as estimates
- Numerical calculations happen in Swift — the AI interprets and narrates, it doesn't compute
- SAM never fabricates data points — if data is insufficient for analysis, it tells you
- Analysis caches with a TTL (pipeline refreshes every 4 hours, patterns daily) to avoid redundant processing

---

## See Also

- **Dashboard Overview** — The Business command center where Strategic Insights is one of four tabs
- **Content Drafts** — Create social media posts from the content ideas Strategic Insights suggests
- **Goals** — The business targets that strategic recommendations help you achieve
