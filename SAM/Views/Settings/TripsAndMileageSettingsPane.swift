//
//  TripsAndMileageSettingsPane.swift
//  SAM
//
//  Settings pane for IRS mileage tracking: rate, office address, and vehicle management.
//

import SwiftUI

struct TripsAndMileageSettingsPane: View {
    @AppStorage("sam.irsRatePerMile") private var irsRatePerMile: Double = 0.70
    @AppStorage("sam.officeAddress") private var officeAddress: String = ""

    @State private var vehicles: [String] = loadVehicles()
    @State private var showAddVehicle = false
    @State private var newVehicleName = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("IRS Rate per Mile")
                    Spacer()
                    TextField("0.70", value: $irsRatePerMile, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Standard IRS mileage rate for this tax year (2025: $0.70/mi). Update each January if the IRS adjusts the rate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("IRS Mileage Rate")
            }

            Section {
                TextField("e.g., 123 Main St, San Diego, CA 92101", text: $officeAddress)
                    .textFieldStyle(.roundedBorder)
                Text("Your regular office address. Trips between home and this address are considered commuting and are not tax-deductible. This is stored for your reference only and is not used for automatic detection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Regular Office Address")
            }

            Section {
                List {
                    ForEach(vehicles, id: \.self) { vehicle in
                        HStack {
                            Image(systemName: "car.fill")
                                .foregroundStyle(.secondary)
                            Text(vehicle)
                            if vehicle == "Personal Vehicle" || vehicle == "Rental" {
                                Spacer()
                                Text("Default")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        let protected = Set(["Personal Vehicle", "Rental"])
                        let toRemove = Set(offsets.map { vehicles[$0] }.filter { !protected.contains($0) })
                        vehicles.removeAll { toRemove.contains($0) }
                        saveVehicles()
                    }
                }
                Button {
                    showAddVehicle = true
                } label: {
                    Label("Add Vehicle", systemImage: "plus")
                }
            } header: {
                Text("Vehicles")
            } footer: {
                Text("\"Personal Vehicle\" and \"Rental\" cannot be removed. Add vehicles like \"2022 Honda CR-V\" for more detailed records.")
            }

            Section {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("What counts as commuting?", systemImage: "info.circle")
                            .font(.subheadline.weight(.medium))
                        Text("Trips between your home and your regular office are commuting — they are not tax-deductible under IRS rules. Trips from your home or office to client meetings, prospect visits, training, or other business locations are deductible.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Mark a trip as \"Commuting\" in the trip review screen to exclude it from your business miles total.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(4)
                }
            } header: {
                Text("About Commuting Trips")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Trips & Mileage")
        .alert("Add Vehicle", isPresented: $showAddVehicle) {
            TextField("e.g., 2022 Honda CR-V", text: $newVehicleName)
            Button("Add") {
                let trimmed = newVehicleName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !vehicles.contains(trimmed) {
                    vehicles.append(trimmed)
                    saveVehicles()
                }
                newVehicleName = ""
            }
            Button("Cancel", role: .cancel) { newVehicleName = "" }
        } message: {
            Text("Enter a name for the vehicle (e.g., \"2022 Honda CR-V\").")
        }
        .onAppear {
            vehicles = Self.loadVehicles()
        }
    }

    private static func loadVehicles() -> [String] {
        UserDefaults.standard.stringArray(forKey: "sam.vehicles") ?? ["Personal Vehicle", "Rental"]
    }

    private func saveVehicles() {
        UserDefaults.standard.set(vehicles, forKey: "sam.vehicles")
    }
}

#Preview {
    TripsAndMileageSettingsPane()
        .frame(width: 600, height: 500)
}
