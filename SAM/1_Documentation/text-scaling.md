# Text Size Scaling

macOS does not meaningfully scale semantic SwiftUI fonts (`.body`, `.caption`, etc.) via `DynamicTypeSize` — those are fixed point sizes. SAM ships its own scaling.

## How It Works

- Custom environment key `\.samTextScale` propagated from the app root, with a `CGFloat` multiplier (0.88–1.30)
- `SAMTextSize` enum (in `SAMModels-Supporting.swift`) defines Small / Standard / Large / Extra Large with scale factors
- User preference stored in `@AppStorage("sam.display.textSize")`
- Applied via `.environment(\.samTextScale, ...)` on all `WindowGroup` roots in `SAMApp.swift`

## Rule for All View Files

**Use `.samFont(.body)` / `.samFont(.caption, weight: .bold)` etc. instead of `.font(.body)`** for any semantic text style. `.samFont` reads the environment scale and returns explicitly sized fonts.

Hardcoded `.font(.system(size:))` calls (decorative icons, tiny badges) are intentionally excluded from scaling.

**New views must use `.samFont()` instead of `.font()` for semantic text styles.**
