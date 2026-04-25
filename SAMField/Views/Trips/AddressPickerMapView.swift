//
//  AddressPickerMapView.swift
//  SAM Field
//
//  Map-based address picker. Long-press drops a pin at the chosen spot;
//  continuing to drag refines its position. The resolved address is
//  returned to the caller on confirm.
//

import SwiftUI
import MapKit
import CoreLocation

struct AddressPickerMapView: View {
    @Environment(\.dismiss) private var dismiss

    /// Invoked when the user confirms the selection.
    var onConfirm: (PickedAddress) -> Void

    /// Optional starting coordinate. If nil, the map centers on user location.
    var initialCoordinate: CLLocationCoordinate2D?

    @State private var position: MapCameraPosition
    @State private var pinCoordinate: CLLocationCoordinate2D?
    @State private var resolvedAddress: String?
    @State private var resolvedName: String?
    @State private var isReverseGeocoding = false

    init(
        initialCoordinate: CLLocationCoordinate2D? = nil,
        onConfirm: @escaping (PickedAddress) -> Void
    ) {
        self.initialCoordinate = initialCoordinate
        self.onConfirm = onConfirm
        if let c = initialCoordinate {
            _position = State(initialValue: .region(MKCoordinateRegion(
                center: c,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            )))
            _pinCoordinate = State(initialValue: c)
        } else {
            _position = State(initialValue: .userLocation(fallback: .automatic))
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mapArea
                resolvedPanel
            }
            .navigationTitle("Pick Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Address") { confirm() }
                        .disabled(pinCoordinate == nil || isReverseGeocoding)
                }
            }
        }
    }

    // MARK: - Map

    private var mapArea: some View {
        MapReader { proxy in
            ZStack(alignment: .topLeading) {
                Map(position: $position) {
                    if let coord = pinCoordinate {
                        Annotation("", coordinate: coord) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(.red)
                                .shadow(radius: 2)
                        }
                    }
                    UserAnnotation()
                }
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                }
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.35)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                        .onChanged { value in
                            if case .second(true, let drag?) = value,
                               let coord = proxy.convert(drag.location, from: .local) {
                                pinCoordinate = coord
                            }
                        }
                        .onEnded { value in
                            if case .second(true, let drag?) = value,
                               let coord = proxy.convert(drag.location, from: .local) {
                                pinCoordinate = coord
                                Task { await reverseGeocode(coord) }
                            }
                        }
                )

                helperBanner
                    .padding(12)
            }
        }
    }

    private var helperBanner: some View {
        Text(pinCoordinate == nil
             ? "Long-press the map to drop a pin. Keep holding and drag to refine."
             : "Long-press elsewhere to move the pin.")
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.55), in: Capsule())
    }

    // MARK: - Resolved panel

    @ViewBuilder
    private var resolvedPanel: some View {
        if pinCoordinate != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundStyle(.red)
                    if isReverseGeocoding {
                        Text("Looking up address…")
                            .foregroundStyle(.secondary)
                    } else if let resolvedAddress {
                        Text(resolvedAddress)
                    } else {
                        Text("Address not found — tap Use Address to save coordinates only.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isReverseGeocoding {
                        ProgressView().scaleEffect(0.8)
                    }
                }
                if let resolvedName, resolvedName != resolvedAddress {
                    Text(resolvedName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Reverse geocode

    private func reverseGeocode(_ coord: CLLocationCoordinate2D) async {
        isReverseGeocoding = true
        defer { isReverseGeocoding = false }

        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first else {
            resolvedAddress = nil
            resolvedName = nil
            return
        }
        resolvedAddress = item.address?.fullAddress ?? item.name
        resolvedName = item.name
    }

    // MARK: - Confirm

    private func confirm() {
        guard let coord = pinCoordinate else { return }
        let addr = resolvedAddress ?? String(format: "%.5f, %.5f", coord.latitude, coord.longitude)
        onConfirm(PickedAddress(
            formattedAddress: addr,
            coordinate: coord,
            locationName: resolvedName
        ))
        dismiss()
    }
}
