# Voice Dictation

SAM includes on-device voice dictation for hands-free note capture. It's available in every multi-line text input throughout the app.

## How It Works

1. Click the **microphone** button in any note capture area — it turns red and pulses while recording
2. Speak naturally, as long as you need — SAM accumulates your speech across pauses
3. When you stop speaking, SAM automatically **polishes** the transcript:
   - Cleans up filler words ("um," "uh," "you know")
   - Fixes grammar and punctuation
   - Improves readability while preserving your meaning
4. Review the polished text
5. If you prefer the raw transcript, click **"Undo polish"** to revert
6. Save when you're satisfied

## Where It Works

The microphone button appears in:

- **Person detail** note capture area
- **Post-meeting capture** prompts
- **Draft editing** for messages and content
- Any multi-line text editor throughout SAM

## Permissions

Dictation requires two permissions:

| Permission | Purpose | How to Grant |
|-----------|---------|-------------|
| **Microphone** | Access to your Mac's microphone | System Settings > Privacy & Security > Microphone |
| **Speech Recognition** | On-device transcription | System Settings > Privacy & Security > Speech Recognition |

SAM will prompt you the first time you use dictation. You can check the status in Settings > Permissions.

## Privacy

- All transcription uses Apple's **on-device** speech recognition — no audio leaves your Mac
- The AI polish step also runs on-device using Apple Foundation Models
- Neither the audio nor the raw transcript is stored — only the final saved text

## Tips

- Dictation is ideal right after meetings when details are fresh and you can't stop to type
- Speak in complete thoughts — the polisher works better with full sentences than fragments
- You can dictate for as long as you need; SAM handles recognition resets automatically
- Include specific names, dates, and commitments — SAM's note analysis extracts these into action items

---

## See Also

- **Adding Notes** — How SAM analyzes your notes for action items, relationships, and life events
- **Clipboard Capture** — Another fast way to capture conversation evidence without typing
