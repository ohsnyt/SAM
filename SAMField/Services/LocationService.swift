//
//  LocationService.swift
//  SAM Field
//
//  Created by Assistant on 4/8/26.
//  Phase F3: Trip Tracking
//
//  Shared CoreLocation provider for trip tracking.
//

import Foundation
import CoreLocation
import MapKit
import UIKit
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAMField", category: "LocationService")

@MainActor
@Observable
final class LocationService: NSObject {

    static let shared = LocationService()

    private var _manager: CLLocationManager?
    private var manager: CLLocationManager {
        if let m = _manager { return m }
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyBest
        _manager = m
        authorizationStatus = m.authorizationStatus
        return m
    }

    private(set) var currentLocation: CLLocation?
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// Continuation for one-shot location requests
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?

    override private init() {
        super.init()
        // Don't create CLLocationManager here — defer to first use
        // so the authorization prompt appears when the UI is visible.
    }

    /// Enable background tracking — call only after authorization is granted
    /// and the app has the location background mode in Info.plist.
    private func enableBackgroundUpdates() {
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.pausesLocationUpdatesAutomatically = false
    }

    // MARK: - Authorization

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    func requestAuthorization() {
        logger.info("Requesting location authorization, current status: \(String(describing: self.authorizationStatus))")
        if authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            // Already denied/restricted — open Settings
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }

    // MARK: - Location Updates

    func startUpdating() {
        guard isAuthorized else {
            requestAuthorization()
            return
        }
        enableBackgroundUpdates()
        manager.startUpdatingLocation()
        logger.info("Started location updates")
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
        logger.info("Stopped location updates")
    }

    /// Get a single location update.
    func requestCurrentLocation() async -> CLLocation? {
        guard isAuthorized else { return nil }
        return await withCheckedContinuation { continuation in
            locationContinuation = continuation
            manager.requestLocation()
        }
    }

    // MARK: - Geocoding

    /// Reverse geocode a location to a street address.
    func reverseGeocode(_ location: CLLocation) async -> (address: String, name: String?)? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        do {
            let mapItems = try await request.mapItems
            guard let mapItem = mapItems.first, let address = mapItem.address else { return nil }
            return (address: address.fullAddress, name: mapItem.name)
        } catch {
            logger.warning("Reverse geocode failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Distance between two coordinates in miles.
    static func distanceMiles(from: CLLocation, to: CLLocation) -> Double {
        from.distance(from: to) / 1609.344
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.currentLocation = location

            if let continuation = self.locationContinuation {
                self.locationContinuation = nil
                continuation.resume(returning: location)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in logger.error("Location error: \(message)") }
        Task { @MainActor in
            if let continuation = self.locationContinuation {
                self.locationContinuation = nil
                continuation.resume(returning: nil)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            logger.info("Authorization changed: \(String(describing: status))")
        }
    }
}
