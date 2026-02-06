//
//  ContactSyncConfiguration.swift
//  SAM_crm
//
//  App-wide configuration for contact validation and sync behavior.
//  Modify these settings to control how strictly SAM validates contact links.
//

import Foundation

enum ContactSyncConfiguration {
    
    // MARK: - SAM Group Filtering
    
    /// If `true`, contacts must be members of the "SAM" group to remain linked.
    /// If `false`, only contact existence is validated (contact hasn't been deleted).
    ///
    /// **Platform support:**
    ///   • macOS: Fully supported (groups are read/write)
    ///   • iOS:   Ignored (groups are read-only; only existence is validated)
    ///
    /// **Recommendation:**
    ///   Set to `true` if you use the SAM group to organize your CRM contacts
    ///   and want SAM to auto-unlink people when they're removed from the group.
    ///   Set to `false` if you want to keep links even when contacts move
    ///   between groups.
    ///
    /// **Default:** `true` (strict — require SAM group membership on macOS)
    static let requireSAMGroupMembership: Bool = true
    
    // MARK: - Validation Timing
    
    /// How long to wait (in seconds) before auto-dismissing the "contacts
    /// unlinked" banner in the UI.
    ///
    /// **Default:** 5 seconds
    static let bannerAutoDismissDelay: TimeInterval = 5.0
    
    /// Whether to run an initial validation pass when the app launches.
    ///
    /// If `true`, SAM will validate all linked contacts on startup to catch
    /// any stale links that accumulated while the app was not running.
    ///
    /// If `false`, validation only happens when `CNContactStoreDidChange`
    /// fires (i.e., when the user makes a change while SAM is running).
    ///
    /// **Default:** `true` (recommended)
    static let validateOnAppLaunch: Bool = true
    
    /// Whether to automatically deduplicate people after Contacts permission is granted.
    ///
    /// If `true`, SAM will merge duplicate people that were created when contacts
    /// were incorrectly marked as unlinked during the permission request flow.
    ///
    /// This fixes the issue where linked contacts appear twice (once linked,
    /// once unlinked) after a fresh build when Contacts permission is requested.
    ///
    /// **Default:** `true` (recommended)
    static let deduplicateAfterPermissionGrant: Bool = true
    
    /// Whether to automatically deduplicate people every time the app launches
    /// when permission is already granted.
    ///
    /// If `true`, SAM will merge duplicate people on every launch (not just after
    /// permission grant). This ensures any duplicates that slip through are cleaned up.
    ///
    /// **Default:** `true` (recommended)
    static let deduplicateOnEveryLaunch: Bool = true
    
    // MARK: - Debugging
    
    /// Enable verbose logging for contact validation.
    ///
    /// When `true`, prints detailed information about:
    ///   • Which contacts are being validated
    ///   • Why a contact failed validation
    ///   • How many links were cleared
    ///
    /// **Default:** `true` (temporarily enabled for testing)
    static let enableDebugLogging: Bool = true
    
    /// Dry-run mode: validate but don't clear invalid links.
    ///
    /// When `true`, validation runs normally and logs what it finds, but
    /// does NOT clear `contactIdentifier` values from SwiftData. This lets
    /// you see what validation thinks is invalid without losing data.
    ///
    /// **Use case:** Debugging contact validation issues. Enable this along
    /// with `enableDebugLogging` to see what's being marked as invalid.
    ///
    /// **Default:** `false`
    static let dryRunMode: Bool = false
}
