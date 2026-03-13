# How SAM Tracks RSVPs

## Automatic RSVP Detection

This is one of SAM's most powerful features for events. You don't have to manually update who's coming — **SAM watches your messages and emails and does it for you.**

### How It Works

1. You send invitations to your event participants
2. People respond via text, email, or other channels
3. SAM's message analysis detects RSVP-like responses:
   - **"Count me in!"** > Accepted
   - **"I can't make it"** > Declined
   - **"Let me check my schedule"** > Tentative
   - **"Can I bring a friend?"** > Tentative + guest detection
4. SAM updates the participant's RSVP status automatically
5. You see the updated status in the participant list

### Confidence Levels

SAM assigns a confidence score to each detection. When SAM is very confident (>80%), it updates the status quietly. When confidence is lower, it flags the detection for your review — you'll see these in the **Unconfirmed** section so you can verify SAM got it right.

![Participant list showing mixed RSVP statuses — Accepted, Tentative, Pending, and Declined](04-01.png)

## When Someone New RSVPs

Here's the scenario: You invited Michelle, and she told her coworker Dave about the event. Dave texts you: "Hey, Michelle told me about the workshop on Thursday — I'd love to come!"

**SAM handles this automatically:**

1. SAM detects the RSVP in Dave's message
2. SAM sees Dave is not on the participant list
3. SAM finds the best matching event (using the day, date, or title mentioned in the message)
4. SAM adds Dave to the participant list with RSVP: Accepted
5. SAM flags this for your review (you'll see a notification banner)
6. You confirm or remove Dave as needed

## When Someone Is Bringing Guests

If someone says "I'll bring Mike and Lisa," SAM:

1. Detects the additional guest names
2. Searches your contacts for Mike and Lisa
3. If found, adds them to the participant list (flagged for your review)
4. If not found, logs it so you're aware

Unnamed guests ("I'm bringing two people from my team") are also tracked so you can plan for the extra attendees.

## Third-Party Invitations

Since you may have referral partners, other agents, or co-hosts also sending invitations, SAM monitors all incoming communications for RSVP signals — not just responses to invitations you sent personally. This means:

- An agent on your team invites someone by phone
- That person texts you saying they're coming
- SAM catches it and adds them to the event

## Auto-Reply to Unknown Senders

When someone you don't know texts about an event, SAM can automatically send a brief holding reply — something like "Thanks for your interest! I'll follow up with details shortly." This buys you time to review who they are.

To enable this:
1. Open your event's settings
2. Turn on **Auto-reply to unknown senders**
3. Make sure **Direct Send** is also enabled in Settings > Messaging

SAM will also post a macOS notification so you know an unknown sender reached out: **"Auto-replied to unknown RSVP — {sender} messaged about {event}."**

## Event Reminders

SAM can automatically send reminders to accepted participants:

- **1 day before:** AI-generated personalized reminders for each accepted attendee
- **10 minutes before:** Join link reminders for virtual or hybrid events

If Direct Send is enabled, reminders go out automatically. Otherwise, SAM drafts them for your review and notifies you: **"Event reminders ready to review."**

## Manual RSVP Updates

You can always update RSVP status manually:
1. Click on a participant in the event detail
2. Use the RSVP controls to set their status
3. Optionally mark it as user-confirmed (so SAM won't override it)

---

## See Also

- **Adding Participants** — How to build and manage your participant list
- **Sending Invitations** — Draft personalized invitations that trigger the RSVP tracking flow
- **Events Overview** — The big picture of event management in SAM
