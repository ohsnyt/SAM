# Swift 6 Task Group Pattern - Avoiding "Sending Closure" Errors

## The Problem

When using task groups (`withTaskGroup`, `withThrowingTaskGroup`), you often see this error:

```
error: Passing closure as a 'sending' parameter risks causing data races between 
       main actor-isolated code and concurrent execution of the closure
```

## Why It Happens

Task group closures run concurrently on any available thread. When you capture variables from the surrounding scope, Swift must ensure those captures are Sendable to prevent data races.

### ❌ WRONG: Direct Capture

```swift
let debugMode = true  // Captured from outer scope
let requireSAM = true

await withTaskGroup(of: Result.self) { group in
    for item in items {
        group.addTask {
            // ❌ Capturing debugMode and requireSAM
            if debugMode {
                print("Processing...")
            }
            if requireSAM {
                validate(item)
            }
        }
    }
}
```

**Problem:** Swift can't verify that `debugMode` and `requireSAM` won't change while the tasks are running (even though they're `let` constants).

## The Solution: Create Local Copies

### ✅ CORRECT: Local Sendable Copies

```swift
let debugMode = true
let requireSAM = true

await withTaskGroup(of: Result.self) { group in
    for item in items {
        // ✅ Create local copies in the loop
        let debugCopy = debugMode
        let reqSAMCopy = requireSAM
        
        group.addTask {
            // ✅ Now capturing local copies
            if debugCopy {
                print("Processing...")
            }
            if reqSAMCopy {
                validate(item)
            }
        }
    }
}
```

**Why it works:** Each iteration creates fresh local copies that are clearly Sendable value types. The compiler can verify there's no shared mutable state.

---

## Real-World Example: ContactsSyncManager

### Before (With Error)

```swift
let debugLoggingEnabled = ContactSyncConfiguration.enableDebugLogging
let reqSAM = requireSAMGroupMembership

await withTaskGroup(of: (UUID, Bool).self) { group in
    for index in 0..<taskCount {
        let personID = taskData[index].0
        let identifier = taskData[index].1
        
        group.addTask {
            // ❌ ERROR: Capturing debugLoggingEnabled and reqSAM
            if reqSAM {
                let result = validate(identifier)
                if debugLoggingEnabled {
                    print("Result: \(result)")
                }
            }
        }
    }
}
```

### After (Fixed)

```swift
let debugLoggingEnabled = ContactSyncConfiguration.enableDebugLogging
let reqSAM = requireSAMGroupMembership

await withTaskGroup(of: (UUID, Bool).self) { group in
    for index in 0..<taskCount {
        let personID = taskData[index].0
        let identifier = taskData[index].1
        
        // ✅ Create local copies
        let reqSAMCopy = reqSAM
        let debugCopy = debugLoggingEnabled
        
        group.addTask {
            // ✅ Use the copies
            if reqSAMCopy {
                let result = validate(identifier)
                if debugCopy {
                    print("Result: \(result)")
                }
            }
        }
    }
}
```

---

## Pattern Variations

### Pattern 1: Simple Value Types

```swift
let threshold = 42
let isEnabled = true

await withTaskGroup(of: Int.self) { group in
    for item in items {
        let thresholdCopy = threshold  // ✅ Local copy
        let enabledCopy = isEnabled
        
        group.addTask {
            if enabledCopy && item.value > thresholdCopy {
                return item.value
            }
            return 0
        }
    }
}
```

### Pattern 2: Reference Types (Already Sendable)

```swift
#if canImport(Contacts)
let contactStore = ContactsImportCoordinator.contactStore  // CNContactStore
#endif

await withTaskGroup(of: Bool.self) { group in
    for identifier in identifiers {
        // ✅ CNContactStore is thread-safe, so we can capture it directly
        // But still create a local reference for clarity
        let store = contactStore
        
        group.addTask {
            return ContactValidator.isValid(identifier, using: store)
        }
    }
}
```

### Pattern 3: Computed Values

```swift
let items = getItems()
let processingMode = determineMode()

await withTaskGroup(of: Result.self) { group in
    for item in items {
        // ✅ Capture item from the loop and create local copies of outer variables
        let mode = processingMode
        
        group.addTask {
            return process(item, mode: mode)
        }
    }
}
```

---

## Common Mistakes

### ❌ Mistake 1: Forgetting to Copy

```swift
let config = getConfig()

await withTaskGroup(of: Result.self) { group in
    for item in items {
        group.addTask {
            // ❌ Directly capturing config
            return process(item, config: config)
        }
    }
}
```

**Fix:**
```swift
let config = getConfig()

await withTaskGroup(of: Result.self) { group in
    for item in items {
        let configCopy = config  // ✅
        
        group.addTask {
            return process(item, config: configCopy)
        }
    }
}
```

### ❌ Mistake 2: Copying Inside the Task

```swift
let setting = getSetting()

await withTaskGroup(of: Result.self) { group in
    for item in items {
        group.addTask {
            let settingCopy = setting  // ❌ Too late
            return process(item, setting: settingCopy)
        }
    }
}
```

**Fix:**
```swift
let setting = getSetting()

await withTaskGroup(of: Result.self) { group in
    for item in items {
        let settingCopy = setting  // ✅ Copy in the loop
        
        group.addTask {
            return process(item, setting: settingCopy)
        }
    }
}
```

### ❌ Mistake 3: Not Copying Constants

Even `let` constants need local copies:

```swift
let constant = 42  // This is a constant!

await withTaskGroup(of: Int.self) { group in
    for i in 0..<10 {
        group.addTask {
            return i * constant  // ❌ Still needs a copy in Swift 6
        }
    }
}
```

**Fix:**
```swift
let constant = 42

await withTaskGroup(of: Int.self) { group in
    for i in 0..<10 {
        let constantCopy = constant  // ✅
        
        group.addTask {
            return i * constantCopy
        }
    }
}
```

---

## Quick Checklist

When using task groups:

- [ ] ✅ Identify all variables captured from outer scope
- [ ] ✅ Create local copies inside the `for` loop (before `group.addTask`)
- [ ] ✅ Use descriptive names (`debugCopy`, `modeCopy`, etc.)
- [ ] ✅ Only capture the local copies in the task closure
- [ ] ✅ Verify no direct outer-scope variable access in closure

---

## Template

```swift
// Setup phase (outside task group)
let configuration = getConfiguration()
let debugMode = isDebugEnabled()
let threshold = calculateThreshold()

// Task group
await withTaskGroup(of: ResultType.self) { group in
    for item in items {
        // ✅ Create local copies for this iteration
        let configCopy = configuration
        let debugCopy = debugMode
        let thresholdCopy = threshold
        
        // Add task with local copies
        group.addTask {
            // Use only the local copies here
            if debugCopy {
                print("Processing with config: \(configCopy)")
            }
            return process(item, threshold: thresholdCopy)
        }
    }
    
    // Collect results
    var results: [ResultType] = []
    for await result in group {
        results.append(result)
    }
    return results
}
```

---

## Why This Pattern Works

1. **Clear Isolation:** Local copies are clearly scoped to each loop iteration
2. **Value Semantics:** Copies are independent values, not shared references
3. **Compiler Verification:** Swift can verify no data races
4. **Explicit Intent:** Code clearly shows what's being captured

---

## Performance Note

Creating local copies of value types (Bool, Int, String, etc.) has **zero performance overhead**. The compiler optimizes these away—they exist only to satisfy the type checker.

For reference types, you're copying the reference (a pointer), not the object itself, so there's still no meaningful overhead.

---

## Summary

**The Rule:** Before calling `group.addTask`, create local copies of all variables you need to capture.

**The Pattern:**
```swift
for item in items {
    let localCopy = outerVariable  // ✅
    
    group.addTask {
        use(localCopy)
    }
}
```

**The Benefit:** Clean, safe, concurrent code that the Swift 6 compiler can verify.

---

**Related Documents:**
- [All Fixes Complete](SWIFT6_ALL_FIXES_COMPLETE.md)
- [Concurrency Cookbook](/.claude/Concurrency in SAM/5 CONCURRENCY_COOKBOOK.md)
- [Quick Reference](/.claude/Concurrency in SAM/4 CONCURRENCY_QUICK_REFERENCE.md)
