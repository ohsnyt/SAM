//
//  CalendarService.swift
//  SAM_crm
//
//  Created on February 10, 2026.
//  Phase E: Calendar & Evidence
//
//  Actor-isolated service for all EKEventStore operations.
//  Returns only Sendable DTOs (EventDTO).
//  Checks authorization before every data access.
//

import Foundation
import EventKit
import AppKit  // Required for NSColor color space conversion

/// Actor-isolated service that owns the EKEventStore and provides
/// thread-safe access to calendar data.
///
/// **Architecture Pattern**:
/// - All EKEventStore access goes through this actor
/// - Returns only Sendable DTOs (EventDTO)
/// - Checks authorization before every operation
/// - Never requests authorization (Settings-only)
/// - Singleton pattern to avoid duplicate stores
actor CalendarService {
    
    // MARK: - Singleton
    
    static let shared = CalendarService()
    
    // MARK: - Properties
    
    private let eventStore = EKEventStore()
    
    // MARK: - Initialization
    
    private init() {
        print("📅 [CalendarService] Initialized")
    }
    
    // MARK: - Authorization
    
    /// Check current authorization status.
    /// Never triggers permission dialog.
    func authorizationStatus() -> EKAuthorizationStatus {
        if #available(macOS 14.0, *) {
            return EKEventStore.authorizationStatus(for: .event)
        } else {
            return EKEventStore.authorizationStatus(for: .event)
        }
    }
    
    /// Request authorization (Settings-only, never call from background).
    /// Returns true if authorized.
    func requestAuthorization() async -> Bool {
        print("📅 [CalendarService] Requesting calendar authorization...")
        
        if #available(macOS 14.0, *) {
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                print("📅 [CalendarService] Authorization result: \(granted)")
                return granted
            } catch {
                print("❌ [CalendarService] Authorization error: \(error)")
                return false
            }
        } else {
            // Fallback for older macOS versions
            return await withCheckedContinuation { continuation in
                eventStore.requestAccess(to: .event) { granted, error in
                    if let error = error {
                        print("❌ [CalendarService] Authorization error: \(error)")
                    }
                    continuation.resume(returning: granted)
                }
            }
        }
    }
    
    // MARK: - Fetch Calendars
    
    /// Fetch all calendars (requires authorization).
    /// Returns nil if not authorized.
    func fetchCalendars() -> [CalendarDTO]? {
        guard authorizationStatus() == .fullAccess else {
            print("⚠️ [CalendarService] Not authorized to fetch calendars")
            return nil
        }
        
        let calendars = eventStore.calendars(for: .event)
        return calendars.compactMap { calendar in
            CalendarDTO(from: calendar)
        }
    }
    
    /// Find calendar by title (case-insensitive).
    func findCalendar(byTitle title: String) -> CalendarDTO? {
        guard let calendars = fetchCalendars() else { return nil }
        
        let lowercaseTitle = title.lowercased()
        return calendars.first { $0.title.lowercased() == lowercaseTitle }
    }
    
    /// Find calendar by identifier.
    func findCalendar(byIdentifier identifier: String) -> CalendarDTO? {
        guard authorizationStatus() == .fullAccess else {
            print("⚠️ [CalendarService] Not authorized to fetch calendar")
            return nil
        }
        
        guard let calendar = eventStore.calendar(withIdentifier: identifier) else {
            return nil
        }
        
        return CalendarDTO(from: calendar)
    }
    
    // MARK: - Fetch Events
    
    /// Fetch events from specific calendars within date range.
    /// Returns nil if not authorized.
    func fetchEvents(
        from calendars: [String],
        startDate: Date,
        endDate: Date
    ) -> [EventDTO]? {
        guard authorizationStatus() == .fullAccess else {
            print("⚠️ [CalendarService] Not authorized to fetch events")
            return nil
        }
        
        // Find EKCalendar objects by identifier
        let ekCalendars = calendars.compactMap { identifier in
            eventStore.calendar(withIdentifier: identifier)
        }
        
        guard !ekCalendars.isEmpty else {
            print("⚠️ [CalendarService] No valid calendars found")
            return []
        }
        
        // Create predicate
        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: ekCalendars
        )
        
        // Fetch events
        let events = eventStore.events(matching: predicate)
        
        print("📅 [CalendarService] Fetched \(events.count) events from \(calendars.count) calendars")
        
        return events.map { EventDTO(from: $0) }
    }
    
    /// Fetch all events from specific calendars (last 30 days + next 90 days).
    func fetchRecentAndUpcomingEvents(from calendars: [String]) -> [EventDTO]? {
        let calendar = Calendar.current
        let now = Date()
        
        // Last 30 days
        guard let startDate = calendar.date(byAdding: .day, value: -30, to: now) else {
            return nil
        }
        
        // Next 90 days
        guard let endDate = calendar.date(byAdding: .day, value: 90, to: now) else {
            return nil
        }
        
        return fetchEvents(from: calendars, startDate: startDate, endDate: endDate)
    }
    
    /// Fetch a single event by identifier.
    func fetchEvent(identifier: String) -> EventDTO? {
        guard authorizationStatus() == .fullAccess else {
            print("⚠️ [CalendarService] Not authorized to fetch event")
            return nil
        }
        
        guard let event = eventStore.event(withIdentifier: identifier) else {
            print("⚠️ [CalendarService] Event not found: \(identifier)")
            return nil
        }
        
        return EventDTO(from: event)
    }
    
    // MARK: - Validation
    
    /// Check if event identifier exists.
    func eventExists(identifier: String) -> Bool {
        guard authorizationStatus() == .fullAccess else {
            return false
        }
        
        return eventStore.event(withIdentifier: identifier) != nil
    }
    
    // MARK: - Write Operations
    
    /// Create a new calendar with the given title.
    /// Returns true if successful.
    func createCalendar(titled title: String) async -> Bool {
        guard authorizationStatus() == .fullAccess else {
            print("⚠️ [CalendarService] Not authorized to create calendar")
            return false
        }
        
        do {
            let newCalendar = EKCalendar(for: .event, eventStore: eventStore)
            newCalendar.title = title
            
            // Find the local source (iCloud or On My Mac)
            guard let source = eventStore.sources.first(where: { $0.sourceType == .local || $0.sourceType == .calDAV }) else {
                print("⚠️ [CalendarService] No suitable calendar source found")
                return false
            }
            
            newCalendar.source = source
            
            try eventStore.saveCalendar(newCalendar, commit: true)
            
            print("✅ [CalendarService] Successfully created calendar '\(title)'")
            return true
        } catch {
            print("❌ [CalendarService] Failed to create calendar '\(title)': \(error)")
            return false
        }
    }
    
    // MARK: - Change Notifications
    
    /// Set up notification observer for calendar changes.
    /// Coordinator should call this to receive change notifications.
    nonisolated func observeCalendarChanges(handler: @escaping @Sendable () -> Void) {
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { _ in
            handler()
        }
    }
}

// MARK: - CalendarDTO

/// Sendable wrapper for EKCalendar
struct CalendarDTO: Sendable, Identifiable {
    let id: String  // calendarIdentifier
    let title: String
    let type: CalendarType
    let color: ColorComponents?
    let isImmutable: Bool
    let allowsContentModifications: Bool
    
    enum CalendarType: String, Sendable {
        case local
        case calDAV
        case exchange
        case subscription
        case birthday
        case unknown
    }
    
    struct ColorComponents: Sendable {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }
    
    nonisolated init(from calendar: EKCalendar) {
        self.id = calendar.calendarIdentifier
        self.title = calendar.title
        self.isImmutable = calendar.isImmutable
        self.allowsContentModifications = calendar.allowsContentModifications
        
        // Map type
        switch calendar.type {
        case .local:
            self.type = .local
        case .calDAV:
            self.type = .calDAV
        case .exchange:
            self.type = .exchange
        case .subscription:
            self.type = .subscription
        case .birthday:
            self.type = .birthday
        @unknown default:
            self.type = .unknown
        }
        
        // Extract color components
        #if os(macOS)
        if let nsColor = calendar.color {
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            
            // Convert to RGB color space if needed
            if let rgbColor = nsColor.usingColorSpace(.deviceRGB) {
                rgbColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                self.color = ColorComponents(
                    red: Double(red),
                    green: Double(green),
                    blue: Double(blue),
                    alpha: Double(alpha)
                )
            } else {
                self.color = nil
            }
        } else {
            self.color = nil
        }
        #else
        self.color = nil
        #endif
    }
}
