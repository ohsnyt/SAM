# LLM Status Indicator Implementation

**Date:** February 7, 2026  
**Feature:** Real-time UI feedback for LLM analysis operations

## Overview

Added a status bar indicator that shows when the LLM (Foundation Models) is analyzing note content. The indicator appears at the bottom of the app window and displays "Analyzing note..." while the AI is processing, then automatically disappears when analysis completes.

## Architecture

### 1. **LLMStatusTracker** (New File: `LLMStatusTracker.swift`)
- `@MainActor` `@Observable` singleton that tracks LLM activity state
- Properties:
  - `isAnalyzing: Bool` - Whether analysis is in progress
  - `statusMessage: String` - Human-readable status text
- Methods:
  - `beginAnalysis(message:)` - Call when starting LLM operation
  - `endAnalysis()` - Call when operation completes (success or error)
  - `track(message:operation:)` - Convenience wrapper for async operations
- Supports concurrent operations via internal task counter

### 2. **LLMStatusBar** (New Component in `AppShellView.swift`)
- Private view component that observes `LLMStatusTracker.shared`
- Only visible when `isAnalyzing == true`
- Design:
  - Small progress indicator (spinning wheel)
  - Status message text
  - `.regularMaterial` background (native macOS glass effect)
  - Smooth slide-in/out animation from bottom edge
- Positioned via `.safeAreaInset(edge: .bottom)` for non-intrusive placement

### 3. **Integration Point** (`InsightGenerator+Notes.swift`)
Modified `InsightGeneratorNotesAdapter.analyzeNote(text:noteID:)` to:
1. Call `LLMStatusTracker.shared.beginAnalysis()` before calling `NoteLLMAnalyzer.analyze()`
2. Call `LLMStatusTracker.shared.endAnalysis()` after analysis completes
3. Ensure `endAnalysis()` is called in error path via additional `catch` handler

## User Experience

### Before
- User clicks "Save" in Add Note sheet
- Note is saved and sheet dismisses
- **No indication that AI processing is happening**
- Insights appear "magically" seconds later

### After
- User clicks "Save" in Add Note sheet
- Note is saved and sheet dismisses
- **Status bar slides in from bottom: "🔄 Analyzing note..."**
- User sees clear feedback that AI is working
- **Status bar slides out when complete**
- Insights appear in Inbox with clear context

## Technical Details

### Thread Safety
- `LLMStatusTracker` is `@MainActor` to ensure all UI updates happen on main thread
- `InsightGeneratorNotesAdapter` is an `actor`, so it calls `await MainActor.run { }` to update the tracker

### Concurrent Operations
- Tracker maintains an internal `activeTaskCount` counter
- Multiple simultaneous analyses keep the indicator visible until all complete
- Supports future extensions (e.g., analyzing multiple notes in batch)

### Error Handling
- `endAnalysis()` is called in both success and error paths
- Ensures status bar doesn't get "stuck" showing if analysis fails
- Debug logging includes status tracker events for troubleshooting

## Files Modified

1. **LLMStatusTracker.swift** (NEW)
   - Observable state tracker for LLM operations
   
2. **InsightGenerator+Notes.swift**
   - Added `beginAnalysis()` call before LLM invocation
   - Added `endAnalysis()` calls after success and in error handler

3. **AppShellView.swift**
   - Added `LLMStatusBar` component
   - Added `.safeAreaInset(edge: .bottom)` modifier to show status bar

## Future Enhancements

### Potential Improvements
1. **Progress Details**: Show which specific operation is running (e.g., "Extracting entities...", "Generating insights...")
2. **Cancellation**: Add ability to cancel in-flight LLM operations
3. **History**: Track and display recent analysis history in dev tools
4. **Error States**: Show brief error toast if analysis fails
5. **Batch Operations**: Extend to show progress for batch note imports

### Additional Use Cases
- Calendar event analysis
- Email thread analysis (future Phase 5)
- Contact enrichment operations
- Document parsing

## Testing Notes

### Manual Testing
1. Open Person detail page
2. Click "Add Note" toolbar button
3. Enter note text and click "Save"
4. **Verify:** Status bar appears immediately with progress indicator
5. **Verify:** Status bar disappears after 1-3 seconds (when analysis completes)
6. **Verify:** Insights appear in Inbox after status bar dismisses

### Edge Cases to Test
- Add multiple notes rapidly (concurrent operations)
- Add note with no FoundationModels available (fallback to heuristics)
- Force-quit during analysis (graceful recovery on relaunch)
- Network/resource errors during analysis

## Performance Impact

- **Minimal overhead**: Tracker is a simple counter + boolean flag
- **No polling**: Uses reactive `@Observable` pattern for UI updates
- **No threading issues**: All UI updates on main actor
- **Efficient animations**: SwiftUI handles view insertion/removal

## Accessibility

- Status bar uses system `.caption` font (respects Dynamic Type)
- Progress indicator is standard macOS component (VoiceOver-friendly)
- Visual-only indicator (consider adding audio cue for blind users in future)

## Design Rationale

### Why Bottom Placement?
- Non-intrusive (doesn't block primary content)
- Standard macOS pattern (like Xcode bottom status bar)
- Easy to implement with `.safeAreaInset(edge:)`

### Why `.regularMaterial`?
- Native macOS look and feel
- Adapts to light/dark mode automatically
- Subtle but visible

### Why Slide Animation?
- Smooth, professional transition
- Draws attention without being jarring
- Standard macOS animation pattern

## Related Documentation

- See `PHASE_5_SIGNAL_GENERATION_FIX.md` for LLM analysis pipeline details
- See `NoteLLMAnalyzer.swift` for Guided Generation implementation
- See `context.md` § "Freeform Notes as Evidence" for feature overview
