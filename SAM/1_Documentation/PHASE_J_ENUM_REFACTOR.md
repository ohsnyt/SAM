# Phase J TODO: Enum Extensibility Review

**Date Created**: February 11, 2026  
**Context**: During Phase G implementation, we discovered that `ContextKind` enum has 8 cases, making exhaustive switch statements brittle and difficult to maintain.

---

## The Problem

Current architecture uses Swift enums for type systems (ContextKind, ProductType, InsightKind, etc.). This creates maintainability issues:

1. **Adding a new type requires changes in multiple files**
   - Update enum definition
   - Update every switch statement that handles all cases
   - Risk of missing one and causing runtime issues

2. **Not user-extensible**
   - Financial advisors have unique practices
   - Can't add custom context types without code changes
   - Limits flexibility of the CRM

3. **Phase G Example**
   - `ContextKind` has 8 cases: household, business, recruiting, personalPlanning, agentTeam, agentExternal, referralPartner, vendor
   - Every UI file with switch statements needs updating when adding `.underwriter` or `.attorney`
   - Temporary fix: Added all 8 cases to switch statements in ContextListView and ContextDetailView

---

## Proposed Solution for Phase J

### 1. Review All Enums

Audit all enums in `SAMModels-Supporting.swift`:

| Enum | Cases | Should Be Extensible? | Reasoning |
|------|-------|----------------------|-----------|
| `ContextKind` | 8 | ✅ YES | Financial advisors need custom types (underwriter, attorney, accountant, carrier, etc.) |
| `ProductType` | 7 | ✅ YES | Insurance products vary by carrier and market. Users may sell products we didn't anticipate. |
| `InsightKind` | 6 | ❓ MAYBE | AI-generated types could be fixed, but custom insights might be useful |
| `EvidenceSource` | 5 | ❌ NO | Fixed set of data sources SAM supports (Calendar, Mail, Contacts, Note, Manual) |
| `EvidenceTriageState` | 2 | ❌ NO | Binary triage system (needsReview / done) |
| `CoverageRole` | 5 | ✅ YES | Insurance roles vary by product type and jurisdiction |
| `ConsentStatus` | 5 | ❌ NO | Compliance state machine should be fixed |
| `JointInterestType` | 5 | ✅ YES | Legal structures vary by state/country |
| `SignalType` | 6 | ❓ MAYBE | Could allow custom AI signal types |

### 2. Refactor Extensible Enums to Struct Pattern

**Before** (current):
```swift
public enum ContextKind: String, Codable, Sendable {
    case household = "Household"
    case business = "Business"
    // ... 6 more cases
}
```

**After** (Phase J):
```swift
public struct ContextKind: Codable, Hashable, Sendable {
    public let rawValue: String
    
    // Predefined constants
    public static let household = ContextKind(rawValue: "household")
    public static let business = ContextKind(rawValue: "business")
    public static let recruiting = ContextKind(rawValue: "recruiting")
    // ... etc
    
    // Allow custom types
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
    
    // Convenience computed property
    public var isStandard: Bool {
        Self.allStandard.contains(self)
    }
    
    public static let allStandard: [ContextKind] = [
        .household, .business, .recruiting, .personalPlanning,
        .agentTeam, .agentExternal, .referralPartner, .vendor
    ]
}
```

**UI Extension** (lookup table approach):
```swift
extension ContextKind {
    var displayName: String {
        let names: [String: String] = [
            "household": "Household",
            "business": "Business",
            "recruiting": "Recruiting",
            "personalPlanning": "Personal Planning",
            "agentTeam": "Agent Team",
            "agentExternal": "External Agent",
            "referralPartner": "Referral Partner",
            "vendor": "Vendor"
        ]
        return names[rawValue] ?? rawValue.capitalized // Graceful fallback
    }
    
    var icon: String {
        let icons: [String: String] = [
            "household": "house.fill",
            "business": "building.2.fill",
            "recruiting": "person.3.fill",
            // ... etc
        ]
        return icons[rawValue] ?? "folder.fill" // Sensible default
    }
    
    var color: Color {
        let colors: [String: Color] = [
            "household": .blue,
            "business": .purple,
            "recruiting": .orange,
            // ... etc
        ]
        return colors[rawValue] ?? .gray // Sensible default
    }
}
```

### 3. Benefits of Struct Approach

✅ **User-extensible**: Financial advisors can define custom types  
✅ **Database-driven**: Can load type definitions from settings/config  
✅ **Graceful degradation**: Unknown types get sensible defaults  
✅ **Future-proof**: No code changes needed for new types  
✅ **Settings UI**: Phase J can add "Manage Context Types" screen  
✅ **No exhaustive switch warnings**: Dictionary lookups always work  

### 4. Migration Strategy

**Phase J Tasks**:

1. **Identify extensible enums** (see table above)

2. **Refactor one at a time**:
   - Start with `ContextKind` (already has pain points)
   - Then `ProductType`
   - Then `CoverageRole` and `JointInterestType`

3. **Update all call sites**:
   - Replace switch statements with dictionary lookups
   - Update pickers/menus to show all types (including custom)
   - Test graceful fallbacks for unknown types

4. **Add Settings UI** (optional, nice-to-have):
   - "Manage Context Types" screen
   - Let users add custom types with name, icon, color
   - Store custom types in UserDefaults or SwiftData
   - Merge standard + custom types in UI

5. **Database migration**:
   - Existing enum raw values (strings) remain compatible
   - No data loss — just switching from enum to struct
   - SwiftData should handle this transparently

### 5. Files to Update in Phase J

**Model Layer**:
- `SAMModels-Supporting.swift` — Refactor enums to structs

**UI Layer**:
- `ContextListView.swift` — Update extension to use dictionary lookups
- `ContextDetailView.swift` — Update extension to use dictionary lookups
- Any other views with ContextKind/ProductType switch statements

**Repository Layer**:
- No changes needed (structs are Codable, Hashable, Sendable)

**Settings**:
- `SettingsView.swift` — Add "Manage Types" tab (optional)
- Create `ManageContextTypesView.swift` (optional)
- Create `ManageProductTypesView.swift` (optional)

---

## Current Status (Phase G)

✅ **Temporary Fix Applied**: All 8 `ContextKind` cases added to switch statements  
✅ **Compiles Successfully**: No more exhaustive switch warnings  
⏳ **Full Refactor Deferred**: Waiting for Phase J (Settings & Polish)  

---

## Decision Log

**Question**: Why not refactor now in Phase G?

**Answer**: 
- Phase G scope is "Contexts feature" — adding CRUD, list, detail views
- Refactoring type system is architectural change affecting multiple phases
- Phase J (Settings & Polish) is appropriate time to:
  - Review all enums holistically
  - Add Settings UI for custom types
  - Ensure consistent approach across all type systems
  - Test extensibility with real user scenarios

**Alternative Considered**: Using `@unknown default` in switch statements

**Rejected Because**:
- Still requires handling all current cases explicitly
- Doesn't solve underlying extensibility problem
- User still can't add custom types
- Future us will still have the same problem

---

## Success Criteria for Phase J

After enum refactoring is complete:

✅ User can create custom context types in Settings  
✅ Custom types appear in pickers and filters  
✅ Custom types get sensible default icons/colors  
✅ No exhaustive switch warnings anywhere in codebase  
✅ Adding new predefined type doesn't require updating 5+ files  
✅ Database stores both standard and custom types transparently  

---

**Priority**: Medium-High  
**Estimated Effort**: 4-6 hours (refactor + test + settings UI)  
**Risk**: Low (backward compatible with existing data)  
**Blocker**: None (can be done incrementally in Phase J)
