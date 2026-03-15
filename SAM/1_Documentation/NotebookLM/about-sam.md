# SAM — Your Intelligent Business Coaching Assistant

## The Problem SAM Solves

An independent financial strategist's most valuable asset is relationships. Not spreadsheets, not CRM records, not pipeline reports — relationships. The people who trust you with their financial future, the agents you mentor, the referral partners who send clients your way, the leads who haven't yet decided to work with you.

But keeping track of relationships is hard. A busy practice means dozens of client meetings per week, hundreds of emails, text threads that go cold, LinkedIn connections that never become conversations, and follow-ups that slip through the cracks. Traditional CRM tools ask you to log every interaction manually — adding friction to the one thing that should feel effortless. And when you do manage to keep your CRM up to date, it gives you a database, not a strategy.

SAM is different. SAM watches, listens, remembers, and coaches — so you can focus on the relationships themselves.

---

## What SAM Is

SAM is a native macOS application that functions as two things simultaneously:

1. **A relationship coach** — observing your interactions across email, messages, phone calls, calendar, and social media, then telling you exactly who needs attention, what to say, and why it matters.

2. **A business strategist** — reasoning across your entire practice (pipeline health, production metrics, time allocation, recruiting progress, content strategy, and goals) to guide the growth of your business.

Both layers feel like a single assistant. You never switch between "relationship mode" and "business mode." When SAM suggests you follow up with a client, it knows that follow-up is also pipeline velocity. When it flags a lead who's been stuck for 30 days, it connects that to your quarterly new-client goal. Every suggestion is grounded in data SAM has already gathered — no manual entry required.

---

## What Makes SAM Unique

### It is not a CRM

Traditional CRMs are databases. You put data in, you query data out. They track what happened, but they don't tell you what to do next or why it matters. They require constant manual input — logging calls, updating stages, recording notes — and the moment you fall behind on data entry, the system becomes unreliable.

SAM is the opposite. It gathers interaction data automatically from the systems you already use (Apple Contacts, Calendar, Mail, iMessage, phone calls, FaceTime, WhatsApp, LinkedIn, Facebook, Substack). It analyzes that data with on-device AI. And it produces specific, actionable coaching — not reports you have to interpret yourself.

### It is not a generic AI assistant

General-purpose AI assistants can draft emails and summarize documents, but they don't know your clients. They don't know that Jennifer has been an applicant for 23 days and the typical conversion window is 14. They don't know that Mike responds to texts within minutes but takes days to reply to emails. They don't know that your recruiting pipeline is decelerating and you need 1.3 new clients per week to hit your annual goal.

SAM knows all of this because it lives inside your practice. Every suggestion references specific people, specific context, and specific reasons. When SAM says "Text Mike about the IUL quote," it has already drafted the message, routed it to iMessage (because that's how Mike prefers to communicate), and connected the action to your pipeline goal.

### Everything stays on your Mac

SAM processes all data locally using Apple's on-device AI. No client names, meeting notes, email contents, or financial details ever leave your computer. There is no cloud backend, no telemetry, no data sharing. This is not a privacy policy — it is an architectural constraint. The AI engine physically cannot send data off your device.

For a financial professional handling sensitive client information, this is not a feature. It is a requirement.

---

## Core Principles

### Outcome-focused, not task-focused

SAM does not say "follow up with clients." It says "Text John about the IUL quote you discussed on Tuesday — he mentioned wanting to finalize before his daughter's birthday on the 15th. Here's a draft message." Every suggestion includes who, what, why, and a ready-to-use artifact.

### Concrete, not vague

Every recommendation names specific people, references specific context from recent interactions, and includes a ready-to-send draft or specific talking points. SAM never says "consider reaching out to your network." It says "Reach out to Maria — it's been 18 days since your last contact, and she mentioned wanting to review her disability coverage."

### Ask when you don't know

When SAM lacks information to make a specific suggestion, it asks — directly and in context. Instead of giving vague advice about lead generation, SAM shows a prompt: "Where are your leads coming from? (Referrals, social media, warm market, events.)" Your answer is stored once and used in every subsequent recommendation, making coaching increasingly specific over time.

### Adaptive, not static

SAM learns from your behavior. Coaching suggestions you consistently act on get prioritized. Suggestions you dismiss get deprioritized. Your preferred encouragement style (direct, supportive, achievement-oriented, or analytical) shapes how SAM communicates. Over months, SAM's action queue becomes a reflection of how you actually work best.

### Noise-aware

One excellent suggestion is worth more than five mediocre ones. SAM respects contact lifecycle states — it never generates outreach for archived, do-not-contact, or deceased contacts. It proactively suggests archiving contacts who have gone silent for over a year. The action queue is kept focused on what matters today.

---

## Relationship Intelligence

### Seeing What You Cannot See

The hardest part of managing dozens of relationships is noticing the ones that are quietly fading. A client you used to talk to every two weeks has gradually slipped to every three weeks, then every five. The gap is widening, but each individual interaction feels normal. By the time you notice, the relationship has cooled.

SAM sees this. For every person in your practice, SAM computes a multi-dimensional relationship health score that goes far beyond "days since last contact":

- **Interaction cadence** — the natural rhythm of your relationship, computed from historical patterns
- **Velocity trend** — is the cadence accelerating, steady, or decelerating?
- **Quality-weighted engagement** — a 30-minute phone call contributes more to relationship health than a brief text
- **Overdue ratio** — how far past the natural cadence you've drifted
- **Decay risk prediction** — SAM predicts when a relationship will reach a critical threshold, days before it happens

Different roles have different thresholds. A client relationship turning yellow at 21 days is very different from a vendor relationship turning yellow at 60 days. SAM knows the difference and calibrates accordingly.

The result is a simple colored dot next to every name — green, yellow, orange, red — that tells you at a glance where your attention is needed. But behind that dot is a sophisticated predictive model that catches fading relationships before they fade.

### Per-Person Communication Preferences

SAM observes how each person communicates with you. Some people respond to texts in minutes but take days with email. Others prefer phone calls for important conversations. SAM tracks these patterns across 90 days of interaction history and infers per-person channel preferences — not just a single preferred channel, but different channels for different kinds of messages:

- **Quick check-ins** — iMessage or text
- **Detailed discussions** — email or phone
- **Social touchpoints** — LinkedIn or Facebook

When SAM generates a follow-up suggestion, it routes it to the right channel automatically. "Text Mike" versus "Email Sarah" is not guesswork — it is based on how Mike and Sarah actually communicate.

### Family and Relationship Mapping

SAM deduces family relationships from your Apple Contacts data and from signals in your interactions. When it discovers that two clients are married, or that a client's parent is also in your practice, it stores the relationship and surfaces it where it matters:

- Meeting briefings show family connections between co-attendees
- Anniversary dates propagate between spouses for relationship touchpoints
- The visual relationship graph displays family clusters with connecting edges

Before a meeting with a couple, SAM ensures you know they are a couple — preventing the kind of oversight that damages trust.

---

## Meeting Intelligence

### Before the Meeting

For every meeting on your calendar that includes contacts in your practice, SAM automatically builds a briefing containing:

- **Who is attending** — with role badges, pipeline stage, and product holdings
- **Recent interaction history** — your last three touchpoints, with dates and summaries
- **Open action items** — anything you promised to do or follow up on, extracted from previous notes
- **Life events** — recent personal milestones (new baby, job change, anniversary) that deserve acknowledgment
- **Family relationships** — connections between attendees you should be aware of
- **AI-generated talking points** — 3 to 5 specific conversation starters drawn from all of the above

The briefing auto-expands in SAM's Today view when the meeting is less than 15 minutes away, and a system notification reminds you to review it.

Walking into a meeting prepared — knowing what was discussed last time, what promises were made, what life events happened, and what cross-sell opportunities exist — is the difference between a good meeting and a great one. SAM does this preparation for you, every time, automatically.

### After the Meeting

Within minutes of a meeting or phone call ending, SAM detects it and prompts you for notes. The capture interface offers two modes:

**Guided mode** walks you through a structured debrief: Who attended? What was the main outcome? Did you cover the talking points from the briefing? Are the pending action items resolved? What new action items emerged? What is the follow-up plan? Were any life events mentioned?

Each question is contextualized with data from the briefing — SAM does not ask generic questions, it asks "Did you discuss the IUL quote from your last meeting?" because it knows that was a pending topic.

**Freeform mode** provides an open text area with contextual placeholders, ideal for quick voice dictation.

After you dictate or type your notes, SAM automatically:
1. Polishes the text (fixing misheard numbers, dollar amounts, and names)
2. Extracts action items with urgency levels and deadlines
3. Identifies mentioned people and links them to your contacts
4. Detects life events and creates coaching prompts
5. Generates a follow-up draft message for the primary attendee
6. Creates coaching outcomes in your action queue for every action item
7. Updates the relationship summary for each person discussed

A two-minute voice note after a meeting becomes a structured, analyzed, actionable record — with follow-ups already queued.

---

## Note Intelligence

Every note you take in SAM is analyzed by on-device AI through a multi-step pipeline. The analysis extracts:

- **Action items** — with type (follow-up, proposal, research, outreach), urgency (immediate, soon, standard, low), suggested text, and recommended communication channel
- **Mentioned people** — matched to existing contacts, with discovered role information
- **Topics and themes** — recurring subjects across your interactions with a person
- **Life events** — job changes, family milestones, health events, financial transitions
- **Discovered relationships** — when a note reveals that two contacts know each other

From these extractions, SAM builds and maintains a living relationship summary for every person: a narrative overview, key themes, and suggested next steps. This summary is not static — it updates with every new note, email, and message, giving you an always-current picture of where each relationship stands and what to do next.

---

## The Daily Coaching Cycle

### Morning Briefing

Each morning when you open SAM, you see a concise briefing containing:

- **Today's calendar** — meetings with your contacts, with attendee names and relationship context
- **Top priority actions** — the 3 most important items from your coaching queue
- **Relationship alerts** — people predicted to reach overdue status in the next 7 days
- **Goal pacing** — whether you are ahead, on track, behind, or at risk on each business goal
- **Strategic highlights** — pipeline health alerts, time allocation imbalances, and the top business recommendation from SAM's strategic analysis

On Mondays, the briefing includes a weekly priorities digest with goal deadline warnings and content posting cadence.

The morning briefing takes about 60 seconds to read and contains everything you need to plan your day.

### The Action Queue

Throughout the day, SAM maintains a priority-ranked queue of specific coaching suggestions. Each item has:

- A **colored badge** indicating the type (follow-up, preparation, outreach, proposal, compliance review, recruitment, content creation)
- A **priority score** computed from five factors: time urgency, relationship health, role importance, evidence recency, and your historical engagement with similar suggestions
- A **title and rationale** explaining what to do and why
- A **suggested next step** with a pre-generated draft message or script
- A **deadline countdown** for time-sensitive items
- A **channel recommendation** routed to the right communication method for that person

One tap executes the action — opening a compose window with the draft pre-loaded, targeted to the right channel (iMessage, email, phone, FaceTime, WhatsApp, or LinkedIn).

For multi-step outreach, SAM creates linked sequences: "Send email. If no response in 3 days, call. If still no response, send a LinkedIn message." Each step triggers automatically based on elapsed time and whether the person has responded through any channel.

### Evening Recap

At the end of the day, SAM offers a brief recap: meetings completed, actions taken, sequence triggers that fired, and accomplishments. This closes the loop on the day's work and sets up tomorrow's briefing.

---

## Business Intelligence

### The Strategic Coordinator

SAM's business intelligence layer runs in the background during idle time, analyzing your entire practice through four specialized lenses:

**Pipeline Analyst** — Examines your client funnel (Lead to Applicant to Client) and recruiting funnel (Initial Conversation to Producing Agent). Computes conversion rates, time-in-stage averages, velocity trends, and identifies specific people who are stuck. "Jennifer has been an Applicant for 23 days. Your average Applicant converts or falls off at 14 days. She's with AIG — here's what to discuss next."

**Time Analyst** — Categorizes your calendar into 10 activity types (client meetings, prospecting, recruiting, agent training, deep work, admin, personal development, etc.) and identifies imbalances. "You spent 40% of last week on administrative tasks and only 25% on client-facing meetings. Consider blocking two 90-minute deep work sessions for prospecting calls."

**Pattern Detector** — Identifies correlations across your entire interaction history. "Clients referred by existing clients convert three times faster than cold leads." "Tuesday afternoon meetings produce 40% more follow-through than Friday meetings." "Agents who attend 3 or more training sessions in their first month have a 70% licensing success rate."

**Content Advisor** — Analyzes recent meeting topics and client concerns to suggest social media content themes that are directly relevant to your actual conversations. Topics are not generic — they emerge from what your clients are actually asking about.

These four analyses are synthesized into a strategic digest with up to seven prioritized recommendations, each connected to specific people and specific actions. You can act on or dismiss each recommendation, and your feedback trains SAM to prioritize the categories you find most valuable.

### Goal Tracking Without Manual Entry

SAM supports seven goal types that track progress automatically from data it already collects:

- **New clients** — counted from pipeline transitions
- **Policies submitted** — counted from production records
- **Production volume** — summed from premium amounts
- **Recruiting milestones** — counted from recruiting pipeline transitions
- **Meetings held** — counted from calendar evidence
- **Content posts** — counted from logged posts across all platforms
- **Deep work hours** — summed from time tracking entries

For each goal, SAM computes: percent complete, daily and weekly targets needed, pace status (ahead, on track, behind, at risk), and a linear projection. Goals appear in the Today view, morning briefing, and the Business Intelligence dashboard.

"You're on track for 12 new clients this year — you need 1.3 per week and you've averaged 1.5. Your recruiting pipeline is decelerating — at this pace, expect 1 to 2 new producing agents this quarter instead of 3."

Goals are not self-reported progress bars. They advance automatically as you do the work SAM already observes.

### Pipeline Visibility

The Business Intelligence dashboard provides a complete view of your practice:

- **Client pipeline** — funnel visualization, conversion rates, time-in-stage, velocity trend, stuck contacts with specific recommendations
- **Recruiting pipeline** — seven-stage funnel from initial conversation through producing agent, licensing rate, mentoring alerts for agents who have gone quiet
- **Production tracking** — policies by status (submitted, approved, rejected, delivered), by product type, premium totals, pending application aging
- **Cross-sell coverage gaps** — SAM scans each client's product holdings and flags missing coverage types as coaching outcomes

Every metric connects to specific people and specific next actions. A pipeline report is not useful unless it tells you what to do — and SAM always does.

---

## Social Media Integration

### Discovering Potential Clients

SAM integrates with three social platforms — LinkedIn, Facebook, and Substack — not just for profile management but for relationship discovery and lead generation.

**LinkedIn** connections become SAM contacts with interaction history. Connection dates establish relationship timelines. LinkedIn shares and comments contribute to your writing voice analysis. When you import your LinkedIn data, SAM matches connections against your existing contacts and identifies new potential leads among your broader network.

**Facebook** friends and message history provide another interaction signal. Cross-platform analysis compares your LinkedIn and Facebook profiles for consistency — ensuring your professional identity is coherent across platforms.

**Substack** subscriber imports match subscribers against existing contacts and surface unmatched subscribers as potential leads for triage. Posting cadence is tracked with streaks. RSS feed parsing automatically logs your published content.

### Improving Lead Generation Through Content

SAM's Content Advisor suggests social media topics based on what your clients are actually talking about in meetings. If three clients in the past week asked about college funding strategies, SAM suggests "529 Plans vs. IUL for Education Savings" as a LinkedIn article, a Facebook post, or a Substack newsletter.

For each platform, SAM generates drafts that match your existing writing voice — analyzed from your imported posts and shares. The draft for LinkedIn sounds professional and strategic. The draft for Facebook sounds warm and community-oriented. The draft for Substack sounds educational and subscriber-focused. All drafts are scanned for compliance issues before you see them.

Content cadence tracking shows your posting streak per platform, last post date, and nudges you when it has been too long since your last post — because consistency in content creation drives lead generation more than occasional bursts.

### The Clipboard Capture Bridge

For platforms SAM does not integrate with directly — Slack, Teams, WhatsApp Web, Twitter DMs — a system-wide keyboard shortcut (Control-Shift-V) captures conversations from your clipboard. Copy a DM thread, press the hotkey, and SAM parses the conversation structure, matches participants to your contacts, analyzes the content, and creates evidence records. The raw text is discarded after analysis.

This means every professional conversation, on any platform, can become part of your relationship intelligence.

---

## Compliance Awareness

Every outgoing message draft and content post runs through a real-time compliance scanner before you see it. The scanner checks six categories of potentially problematic language:

- **Guarantees** — "guaranteed return," "risk-free," "cannot lose"
- **Returns and performance claims** — "will earn X%," "beat the market"
- **Promises** — "I promise," "definitely will"
- **Comparative claims** — "better than competitors," "best in the industry"
- **Suitability assertions** — "you should," "best for you," "ideal solution"
- **Specific financial advice** — "invest in," "buy this," "put your money in"

Each flag shows the matched phrase and a specific suggestion for rewording. An audit trail records every flagged draft with original and final text.

For a financial professional sending dozens of messages per week, this is a safety net. SAM catches "I guarantee this IUL will outperform a 401(k)" and suggests "this IUL may potentially outperform" before the message is sent.

---

## The Visual Relationship Graph

SAM renders your entire professional network as a visual force-directed graph. Nodes are color-coded by role (green for clients, teal for agents, orange for leads, purple for vendors). Edges represent interactions — meetings, messages, notes, social connections. Family relationships appear as dashed pink connections.

The graph answers questions that lists cannot: Who is connected to whom? Where are the clusters in your network? Which clients were referred by the same source? Which agents share training meetings? Where are the isolated nodes — people in your network who have no connections to anyone else?

Role suggestions from SAM's deduction engine are confirmed directly in the graph view, with batch confirmation for efficiency. Hovering over any node shows relationship health, last interaction, and pending actions.

---

## Event Planning and Execution

### From Idea to Follow-Up in One Place

Client workshops, prospecting seminars, and educational events are powerful growth tools — but they come with logistical overhead that steals time from the relationships you are trying to build. SAM handles that overhead.

**Creating an event** starts with the basics: title, format (in-person, virtual, or hybrid), dates, venue or join link, and target attendance. SAM assigns a lifecycle status — Draft, Inviting, Confirmed, In Progress, Completed, or Cancelled — and advances it as you work through each stage.

**Adding participants** is straightforward. Search your contacts, pick who to invite, and assign a priority level: Standard, Key, or VIP. SAM can also suggest attendees based on relationship history, pipeline stage, and past event attendance. VIP invitees get automatic acknowledgment when they accept.

**Invitation drafting** is where SAM earns its keep. For each participant, SAM writes a personalized invitation that reflects the warmth of your relationship, the person's role, and the event details. A long-standing client receives a warm, first-name message referencing your recent conversations. A new lead gets a professional introduction that explains why the event is relevant to them. SAM learns your preferred closing style — "Best," "Warm regards," "Looking forward to seeing you" — and applies it per relationship type. Batch-draft all invitations with one click, review, and send.

**RSVP tracking** runs automatically. SAM monitors your incoming messages and emails for responses, detecting acceptances, declines, tentative replies, and even requests to bring a guest. High-confidence detections update the participant list silently. Lower-confidence responses are flagged for your review. When someone you did not invite says "I'll be there," SAM identifies them, matches them to your contacts if possible, and adds them to the guest list.

**Social promotion** generates platform-specific posts to market your event. The LinkedIn version emphasizes professional networking value. The Facebook version is conversational and community-oriented. Instagram gets a short, visual caption. Substack produces a newsletter segment. SAM recommends posting timing: two to three weeks out for initial promotion, three to five days before for a reminder, and a post-event recap to sustain momentum.

### Presentation Library

SAM includes a library for your presentation decks and PDFs. Drag and drop a file, and SAM reads the content, generates a summary, extracts key talking points, and tags the document by topic. Link presentations to events, and SAM uses the actual slide content — not generic language — to personalize invitations and marketing copy. Delivery history tracks how many times you have presented each deck, when, and to whom.

Walking into a seminar with talking points pulled from your own slides, invitations that referenced actual session content, and a guest list that tracked itself — that is what SAM provides.

---

## Security

### More Than Privacy — Active Protection

SAM's privacy architecture keeps data on your Mac. Its security architecture keeps that data protected even when your Mac is in someone else's hands.

**Mandatory authentication** is enforced on every launch. Touch ID or your system password — no exceptions, no "remember me" bypass. SAM does not display any client data until you authenticate. If someone opens your laptop while you are away, they see a lock screen, not your practice.

**Idle timeout** re-locks SAM automatically when you step away. The duration is configurable — one minute, five minutes, fifteen minutes, or thirty minutes. When you return, a Touch ID tap gets you back in instantly, but no one else gets in at all.

**Encrypted backups** protect your data at rest. When you export a backup, SAM requires a passphrase and encrypts the entire archive. The backup file is useless without the passphrase. Importing a backup requires authentication first, then the passphrase. No one can restore your practice data on another machine without both your system credentials and your backup passphrase.

**Clipboard auto-clear** protects sensitive content you copy from SAM — draft messages, coaching suggestions, client details. After 60 seconds, SAM clears the clipboard automatically. If you copy something else in the meantime, the clear is skipped (SAM only erases its own content). This prevents client information from lingering on the clipboard where another application could access it.

**Secure credential storage** uses the macOS Keychain with the most restrictive access level — data is available only when the device is unlocked, and only on the device where it was created. Credentials never sync to iCloud Keychain or any other device.

For a financial professional whose laptop contains client names, policy details, meeting notes, and business strategy — security is not a setting you toggle on. SAM enforces it by default, every time.

---

## The Undo Safety Net

Every destructive or significant change in SAM — dismissing a coaching card, deleting a note, removing a participant from a context, completing an outcome — creates an undo snapshot preserved for 30 days. A non-intrusive banner appears for 10 seconds with an undo button.

In a system that makes autonomous suggestions and generates coaching actions, the ability to reverse any decision instantly preserves your trust in the tool.

---

## Getting Started

SAM is designed to become more valuable over time, but it starts delivering insights from day one.

**Day one**: Import your contacts. SAM immediately begins computing relationship health scores from your calendar history, email metadata, and message records. Your first morning briefing shows who needs attention today.

**Week one**: As you take notes after meetings and respond to coaching suggestions, SAM learns your patterns. Relationship summaries build up for your most active contacts. The action queue starts to reflect your priorities.

**Month one**: SAM has a comprehensive view of your practice. Pipeline analytics are meaningful. Time allocation patterns emerge. The Strategic Coordinator produces actionable business intelligence. Content suggestions reflect your actual client conversations. Goal tracking shows real progress.

**Ongoing**: SAM's adaptive coaching continues to sharpen. Suggestions you act on get prioritized. Channels you prefer get recommended. Your writing voice analysis improves with each social media post. The relationship graph grows into a living map of your professional network.

The key insight is that SAM does not require you to change how you work. It observes what you already do — meetings, emails, texts, phone calls, notes — and builds intelligence on top of it. The only new behavior it asks for is this: when SAM suggests an action, consider taking it. The more you engage, the smarter SAM becomes.

---

## Privacy by Design

SAM is built on Apple's on-device AI infrastructure. All processing — note analysis, relationship scoring, meeting preparation, business intelligence, draft generation, compliance scanning — runs locally on your Mac. No data is transmitted to any server. No cloud service has access to your client information. No API key is required.

Email and message bodies are analyzed by the on-device AI and then discarded. Only summaries and extracted insights are stored. Phone call records store metadata only — duration, direction, timestamp — never recordings.

Your practice data exists in one place: on your Mac, in a local database, protected by macOS security. It can be backed up to a file you control and restored on any Mac. That is the entire data architecture.

For a financial professional handling sensitive client information, retirement plans, insurance details, and personal financial goals, this level of privacy is not optional. SAM was designed from the ground up to make cloud processing architecturally impossible — not just policy-prohibited.

---

## Summary

SAM exists because the most important work a financial strategist does — building and maintaining relationships — is also the hardest to systematize. Traditional tools either require too much manual input to be sustainable or provide too little intelligence to be useful.

SAM bridges this gap by observing what you already do, analyzing it with on-device AI, and coaching you with specific, actionable, people-connected suggestions. It is a relationship coach that knows every client's history and a business strategist that sees your entire practice. It drafts your messages, prepares your meetings, captures your notes, tracks your goals, manages your pipeline, plans your events, suggests your content, and watches your compliance — all without sending a single byte of data off your computer, and with security that protects your practice even when you step away from your desk.

The result is a practice where no relationship slips through the cracks, no follow-up is forgotten, no meeting is unprepared, no event runs without a plan, and no business opportunity goes unnoticed.
