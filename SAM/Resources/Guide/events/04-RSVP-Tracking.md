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

## Manual RSVP Updates

You can always update RSVP status manually:
1. Click on a participant in the event detail
2. Use the RSVP controls to set their status
3. Optionally mark it as user-confirmed (so SAM won't override it)

---

**Screenshots to capture:**
1. A participant list showing mixed RSVP statuses (green Accepted, orange Tentative, red Declined)
2. The notification banner that appears when SAM auto-adds someone ("Dave was auto-added to Personal Finance Workshop")
3. An unconfirmed RSVP detection awaiting user review
