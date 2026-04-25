# SAM Onboarding & Help Showcase

## Introduction

SAM believes your first experience should feel guided, not overwhelming. Rather than dumping every feature on you at once, it walks you through setup one clear step at a time, then continues teaching as you explore -- surfacing help exactly when and where you need it.

*Suggested screenshot: getting-started/images/gs-01.png (Today view -- the destination after onboarding)*

## First Launch Experience

When you open SAM for the first time, a focused onboarding sheet guides you through twelve steps at your own pace. It begins with a welcome screen, then moves into permissions and configuration:

1. **Welcome** -- A brief introduction to what SAM does and how the rest of onboarding works.
2. **Contacts permission** -- SAM asks to access Apple Contacts, explaining that it reads but never replaces your address book.
3. **Contact group selection** -- You choose which Contacts group SAM manages. Your personal contacts stay untouched.
4. **Calendar permission** -- SAM requests calendar access to observe your meetings and schedule.
5. **Calendar selection** -- You pick your work calendar so SAM only sees professional events.
6. **Mail permission** -- SAM asks to read your Mail database for interaction history.
7. **Mail address selection** -- You confirm the specific mail accounts SAM should analyze.
8. **Communications permission** -- Covers iMessage, Phone, and FaceTime history via a security-scoped bookmark. SAM analyzes message text on-device and stores only summaries.
9. **Microphone permission** -- Enables on-device voice dictation so you can capture notes hands-free.
10. **Notifications permission** -- Lets SAM send timely alerts for meeting prep and time-sensitive coaching.
11. **AI setup** -- SAM identifies your "Me" contact and configures on-device intelligence (Foundation Models plus an optional MLX model download).
12. **Complete** -- You are ready to go.

Every permission is explained in plain language. Skip any step now and enable it later from Settings.

*SCREENSHOT NEEDED: Onboarding flow showing the contact group selection step*

## Security on First Launch

Before you see any data, SAM requires authentication. On launch, a lock screen appears with your app icon and a single "Unlock" button. If your Mac supports Touch ID, SAM prompts biometric authentication immediately. Otherwise, it falls back to your system password. There are no exceptions and no bypass. You can configure an idle timeout in Settings so SAM re-locks automatically when you step away. A quick Touch ID tap brings you back, but nobody else gets in.

*Suggested screenshot: getting-started/images/TouchID prompt.png (Lock screen with Touch ID authentication)*

## Sidebar Layout

After unlocking, SAM lands you in a three-column NavigationSplitView. The sidebar holds seven sections: **Today** (briefing and outcome queue), **People** (contacts, person detail, and the relationship graph), **Business** (dashboard, goals, pipelines, production, strategic insights), **Grow** (lead acquisition and content drafts), **Events** (event manager and presentation library), **Transcription** (live recording and meeting capture sessions), and **Search** (universal search across everything). Glass material on the sidebar and toolbar follows the macOS 26 Tahoe design language.

## Tooltip System

As you explore SAM for the first time, contextual tips appear right where they are relevant. Each tip is styled with a Liquid Glass card tinted amber so it stands out without interrupting your workflow. SAM ships twenty-seven tips covering Today, People, Business, Grow, Events, Search, and cross-cutting features. A few examples:

- **"Your Top Priority"** -- Introduces the hero coaching card on the Today view and explains how to act on, complete, or skip recommendations.
- **"Your Action Queue"** -- Describes the outcome queue where SAM's coaching suggestions accumulate throughout the day.
- **"Capture Notes"** -- Appears near the note editor and encourages you to add notes after meetings, with a nudge to try voice dictation.
- **"Clipboard Capture"** -- Teaches you the Control-Shift-V shortcut to capture copied conversations from any app.
- **"Quick Commands"** -- Introduces the Command-K command palette for keyboard-first navigation.

Every tip includes a "Learn more" button that opens the matching article in SAM's built-in guide. Tips appear once, then get out of your way. You can re-enable all tips or toggle them off entirely from Settings.

*Suggested screenshot: today/images/td-02.png (Outcome queue area with a tooltip visible)*

## Built-in Guide

SAM includes a fully searchable guide window with eight sections and over fifty articles. The sections are:

1. **Getting Started** -- Welcome, keyboard shortcuts, voice dictation, clipboard capture, settings, privacy, and text size.
2. **Today & Coaching** -- Daily briefing, outcome queue, how coaching works, life event intelligence, and deep work scheduling.
3. **People & Relationships** -- Contact list, person detail, adding notes, and the relationship graph.
4. **Business Dashboard** -- Dashboard overview, goals, client pipeline, recruiting pipeline, production, strategic insights, role recruiting, and goal check-in sessions.
5. **Grow & Content** -- Lead acquisition, content drafts, and social imports.
6. **Events & Presentations** -- Eleven articles covering event creation, participants, invitations, RSVP tracking, social promotion, presentations, identity, and full workflows.
7. **Search** -- Universal search and the command palette.
8. **iOS Companion** -- Thirteen articles dedicated to SAM Field on iPhone (Today, recording, trips, pairing, and mileage export).

Each article is tagged in the manifest as `macOS`, `iOS`, or `both`, so the same companion library serves both apps. Type a keyword and results filter instantly. Every tooltip's "Learn more" link opens the corresponding article, so guidance flows naturally from tip to deeper reading.

*Suggested screenshot: getting-started/images/gs-02.png (Guide window showing section list)*

## Adaptive Learning

SAM learns from you as much as you learn from it. Every time you complete a coaching suggestion, skip it, rate it, or mute a category, SAM records that signal. Over time, it adjusts what it recommends and how it prioritizes. If you consistently act on follow-up reminders but dismiss content suggestions, SAM increases the weight of follow-ups and quietly reduces content noise.

Visit "What SAM Has Learned" in Coaching Settings to see your profile: how many suggestions you have completed, your average rating, which outcome types you prefer, your peak activity hours, and any categories you have muted. You can reset individual categories, unmute types, or start fresh with "Reset All Learning." The result is a coaching assistant that feels more useful every week because it adapts to your real working patterns.

*Suggested screenshot: business/images/bi-01.png (Business dashboard where adaptive insights surface)*
