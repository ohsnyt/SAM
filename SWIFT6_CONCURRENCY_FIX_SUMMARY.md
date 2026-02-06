# Swift 6 Concurrency Fix Summary

## Problem: Actor Isolation Inference Hell

These errors were caused by Swift 6's aggressive actor isolation inference, which "leaks" MainActor requirements through:
1. Extensions on types that contain MainActor methods
2. Helper types defined in the same file as actors
3. Protocol conformances that reference actor-isolated types

## The Fixes

### 1. InsightGenerator Helper Types → Separate File

**Problem:**
```swift
// Inside InsightGenerator.swift
actor InsightGenerator {
    // ...
}

private struct InsightGroupKey: Sendable, Hashable {
    // Even with Sendable + Hashable, the conformance inherits
    // MainActor isolation from being in the same file as the actor
}
```

**Solution:** Move helper types to `InsightGeneratorTypes.swift`
```swift
// InsightGeneratorTypes.swift
struct InsightGroupKey: Sendable, Hashable {
    let personID: UUID?
    let contextID: UUID?
    let signalKind: SignalKind
}
```

**Why it works:** Types defined in a separate file don't inherit isolation from actor contexts in other files.

### 2. SAMModelContainer.shared → nonisolated(unsafe)

**Problem:**
```swift
enum SAMModelContainer {
    static let shared: ModelContainer = { ... }()
}

extension SAMModelContainer {
    @MainActor
    static func seedOnFirstLaunch() { ... }
}
```

The `@MainActor` method in the extension causes the **entire enum** to be inferred as MainActor-isolated, including `shared`.

**Solution:** Explicitly mark `shared` as `nonisolated(unsafe)`
```swift
enum SAMModelContainer {
    nonisolated(unsafe) static let shared: ModelContainer = { ... }()
}
```

**Why `nonisolated(unsafe)` and not just `nonisolated`:**
- `ModelContainer` is `Sendable`, so it's safe to access from any isolation domain
- The `unsafe` keyword acknowledges that we're overriding the compiler's inference
- This is the correct pattern when you have a Sendable static let that's being incorrectly inferred as MainActor-isolated due to sibling members

## Key Lessons

### Lesson 1: Separate Helper Types from Actors
If you have helper structs used by an actor, define them in a separate file. Even `Sendable` + `Hashable` types can inherit isolation contamination.

### Lesson 2: Extensions Can Poison the Well
Adding a `@MainActor` method to an enum/struct via extension can cause **all** static members to inherit that isolation, even if they're defined in the primary declaration.

### Lesson 3: `nonisolated(unsafe)` is Sometimes Necessary
Despite the warning that "`nonisolated(unsafe)` is unnecessary for Sendable types", it **is** necessary when:
- The type is Sendable
- The compiler has incorrectly inferred MainActor isolation due to context
- You need to explicitly opt out of that inference

### Lesson 4: Trust But Verify
Synthesized protocol conformances (like `Hashable`) can inherit isolation from their definition context. When in doubt, move types to their own file.

## Testing

After these changes, all Swift 6 concurrency errors should be resolved:
1. ✅ `SAMModelContainer.shared` accessible from any context
2. ✅ `InsightGroupKey` and `InsightDedupeKey` usable in actor-isolated dictionary operations
3. ✅ No MainActor isolation leakage

## References
- [Swift Forums: Actor isolation inference](https://forums.swift.org/t/actor-isolation-inference-with-sendable-types)
- [SE-0313: Improved Control Over Actor Isolation](https://github.com/apple/swift-evolution/blob/main/proposals/0313-actor-isolation-control.md)
