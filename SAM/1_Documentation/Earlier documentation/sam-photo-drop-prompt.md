# SAM Feature: Drag-and-Drop / Paste Photo for Contacts

## Overview

Implement the ability for users to drag an image (from Safari or any source) or paste an image from the clipboard onto a contact's photo area in SAM. The image should be resized appropriately and written to Apple Contacts via `CNContactStore`, since SAM does not store contact photos locally — it fetches them from Apple Contacts as the source of truth.

## Requirements

### Drop Target
- Add a drop target to the contact's photo/avatar area in the contact detail view.
- Accept both `NSImage` bitmap data and image URLs from the pasteboard (Safari drags may provide either or both).
- If a URL is received instead of raw image data, download the image from the URL before processing.
- Provide visual feedback on drag hover (e.g., highlight or overlay indicating "Drop photo here").

### Clipboard Paste
- Support ⌘V paste of image data onto the contact's photo area (or via a "Paste Photo" context menu / button).
- Source image from `NSPasteboard.general`.
- Shares the same resize and write logic as the drop path.

### Image Processing
- Resize to a maximum of 600×600 pixels.
- Center-crop to square before resizing (Contacts displays photos as circular crops, so square source looks best).
- Compress to JPEG with ~0.85 quality to keep iCloud Contacts sync performant.
- Handle common input formats: JPEG, PNG, TIFF, HEIC, WebP.

### Write to Apple Contacts
- Look up the corresponding `CNContact` by identifier.
- Create a `CNMutableContact`, set `imageData` with the processed JPEG data.
- Save via `CNSaveRequest` through `CNContactStore`.
- SAM's existing photo-fetch logic should then pick up the new image naturally on next read — verify this works without any additional changes.
- Handle the case where Contacts write permission hasn't been granted yet (it should already be authorized, but guard against it).

### Error Handling
- Invalid/corrupt image data: show a brief inline error (not an alert).
- Network failure when downloading from a URL: show appropriate feedback.
- Contacts save failure: surface the error to the user.

## Architecture Guidance

Follow SAM's existing layered architecture:

- **View layer**: Drop target modifier and paste handler on the contact photo view. Visual feedback for drag state.
- **Coordinator**: Mediates between the view action and the service. Orchestrates the resize → write flow.
- **Service**: `ContactPhotoService` (or extend an existing service) — handles image downloading (if URL), resizing/cropping, JPEG compression, and the `CNContactStore` write. This should be an actor per SAM's Swift 6 concurrency conventions.
- **Repository**: If Contacts writes go through an existing repository, use that. Otherwise the service can own the `CNContactStore` interaction for photo writes specifically.

## Implementation Notes

- Use `UTType.image` and related uniform type identifiers for drop/paste type conformance.
- For the drop target, `onDrop(of:)` or `dropDestination(for:)` — use whichever is appropriate for SAM's minimum deployment target.
- For downloading from a URL, use `URLSession` — keep it async.
- The resize/crop logic should be a reusable utility since it may be useful elsewhere (e.g., if we add photo capture later).

## Testing Checklist

After implementation, manually verify:
- [ ] Drag a photo from Safari onto a contact → photo appears in SAM and in Apple Contacts
- [ ] Drag a PNG, JPEG, and WebP → all work
- [ ] Paste an image via ⌘V → same result
- [ ] Drag an oversized image (e.g., 4000×3000) → confirm it's resized to 600×600 square
- [ ] Drag onto a contact that already has a photo → photo is replaced
- [ ] Drag invalid data (text, a file that isn't an image) → graceful rejection with feedback
