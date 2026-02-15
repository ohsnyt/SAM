You are an expert full-stack UI/UX engineer and cognitive-science-informed designer. Your task is to design and implement a web-based long-form reading interface (React 19 + TypeScript + Tailwind CSS + shadcn/ui + Zustand for state) that **maximizes comprehension, retention, and sustained engagement** for informational/expository texts (articles, textbooks, research papers, essays).

### Core Research Foundation (include these principles in every design decision)
- **Screen Inferiority Effect** (Delgado et al. 2018 meta-analysis of 54 studies; Clinton 2019; 2024 meta-analysis of 49 studies): print outperforms screens on comprehension and memory, especially for complex informational text, under time pressure, and for less-skilled readers. Effect size small-to-moderate but consistent.
- **Mechanisms to counteract**:
  - Reduced spatial mental mapping & fewer regressive saccades on screens.
  - Higher cognitive load, more mind-wandering (theta/alpha brain waves vs. beta/gamma on paper).
  - Metacognitive illusion (readers feel more confident but understand less).
  - Attentional interference from distractions (meta-analysis shows large negative effect, Hedges’ g ≈ −0.64).
- **UI/UX levers that reliably improve digital reading** (backed by studies):
  - Distraction-free / reader-mode interfaces dramatically reduce extraneous load.
  - Pagination vs. scrolling: mixed results, but pagination helps low working-memory readers, improves structural recall, and equalizes performance across ability levels (recent educational studies). Offer both, default to user choice + “smart” recommendation.
  - Typography: font size up to 18 pt improves readability/comprehension; line spacing 1.2–1.5× optimal; line length 60–80 characters; generous whitespace.
  - High contrast, minimal visual noise, stable layout (no reflow surprises).

### Primary Goals
1. **Comprehension & Retention** > speed or novelty.
2. **Sustained deep focus** (minimize mind-wandering and multitasking temptation).
3. **Active reading support** without adding extraneous cognitive load.
4. **Accessibility & inclusivity** (dyslexia-friendly options, high contrast, keyboard-first).

### Required Features & Exact Implementation Guidelines

#### 1. Reading Modes (toggleable with persistent preference)
- **Distraction-Free Full-Screen Mode** (default): no browser chrome, no sidebars, no floating buttons until hover or keyboard shortcut. Background: pure off-white (#F8F5F0) or warm paper tones; optional subtle page texture.
- **Pagination Mode** (highly recommended for complex text):
  - Fixed viewport “pages” that fill the readable area.
  - Smooth page-turn animation (subtle, <300 ms, optional disable).
  - Page numbers + progress (e.g., “Page 7 of 23”).
  - Keyboard: ← → or space; swipe on touch.
- **Continuous Scroll Mode** (for lighter reading):
  - With visual landmarks: every major heading has a persistent left-margin marker + progress bar segments.
  - Optional “mini-map” TOC on the right (collapsible) that highlights current section.

#### 2. Typography & Layout Controls (live preview, saved per user)
- Font size: 14–24 px (default 18 px) — larger sizes proven to boost comprehension.
- Line spacing: 1.2× / 1.4× / 1.6× / 1.8× (default 1.4×).
- Font family presets:
  - Serif (Georgia or Literata) — for long-form feel.
  - Sans (Inter or System UI) — default.
  - Dyslexia-friendly (OpenDyslexic or Atkinson Hyperlegible).
- Max line length: 66 characters (adjustable 50–80).
- High-contrast mode (black on off-white or dark mode with warm tint).
- Optional “E-ink simulation”: grayscale + reduced contrast + no animations.

#### 3. Spatial & Cognitive Mapping Aids
- Persistent left or right narrow TOC that scrolls with content and highlights current section.
- In scroll mode: subtle vertical progress bar segmented by headings.
- “Jump to page/section” search.
- Saved bookmarks with user notes.

#### 4. Active Reading Tools (minimalist)
- Text selection → highlight (3 colors) + private note (saved to localStorage or optional backend).
- Inline search (Cmd/Ctrl + F) with highlighted matches.
- “Focus mode” that dims everything except the current paragraph (optional).

#### 5. Engagement & Metacognition (subtle, non-gamified)
- Estimated reading time (updated live).
- Gentle progress ring at top (fills as you advance).
- At end: optional 3-question self-quiz (user can skip) to combat metacognitive illusion.
- Session timer (visible only if user enables).

#### 6. Technical & UX Requirements
- Fully responsive (mobile-first; on phones default to scroll but offer pagination).
- Keyboard-first navigation (all controls accessible via Tab + shortcuts).
- ARIA labels, reduced motion respect, high contrast WCAG AA+.
- No ads, notifications, or any external distractions.
- State persistence (localStorage): last reading position, preferences, highlights.
- Performance: lazy-load long texts; virtual scrolling if needed.

### Deliverables (produce in order)
1. Complete folder structure and package.json (Next.js 15 App Router recommended).
2. Main `Reader.tsx` component with all modes and controls.
3. Typography control panel (floating or top bar, collapsible).
4. Sample Markdown or HTML content loader (support both).
5. Detailed README explaining every research-backed decision.

Start by showing me the high-level component architecture and the exact Tailwind + shadcn components you will use. Then implement step-by-step, explaining the cognitive rationale for each major feature.

Begin.
1
