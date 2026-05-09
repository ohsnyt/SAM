//
//  LockModifiers.swift
//  SAM
//
//  ViewModifiers that connect SwiftUI presentation state to
//  `ModalCoordinator`. Drop one onto each `.alert(...)` /
//  `.confirmationDialog(...)` / `.sheet(...)` site and the modal will
//  dismiss cleanly when the app locks (and, for restorable sheets,
//  re-present after unlock with the same selection).
//
//  Why per-site modifiers instead of a global sweep:
//  SwiftUI presentation state lives in `@State` on the host view. Setting
//  the binding to `false`/`nil` is the only way to ask SwiftUI to tear
//  down the modal cleanly — calling `NSWindow.close()` on the modal
//  window leaves SwiftUI's presentation state out of sync. So each site
//  hands its binding to the coordinator, the coordinator flips it, and
//  SwiftUI does the rest.
//

import SwiftUI

// MARK: - DismissOnLock

/// Apply to a view that hosts an `.alert(...)` or `.confirmationDialog(...)`.
/// While the alert is presented, the modifier registers a dismiss callback
/// with `ModalCoordinator`. On lock, the coordinator flips the binding to
/// `false`, which dismisses the alert. The user re-triggers it if needed —
/// alerts are not restored on unlock.
///
/// Usage:
/// ```
/// .alert("Discard changes?", isPresented: $showAlert) { ... }
/// .modifier(DismissOnLock(isPresented: $showAlert))
/// ```
struct DismissOnLock: ViewModifier {

    @Binding var isPresented: Bool

    /// Held in @State so it survives view updates. We capture/release it
    /// in lockstep with `isPresented` flipping.
    @State private var registration: ModalCoordinator.Registration?

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented, initial: true) { _, newValue in
                if newValue {
                    let reg = ModalCoordinator.shared.registerDismissOnly(
                        dismiss: { isPresented = false }
                    )
                    registration = reg
                } else {
                    registration?.unregister()
                    registration = nil
                }
            }
    }
}

extension View {
    /// Convenience wrapper. Equivalent to `.modifier(DismissOnLock(isPresented:))`.
    func dismissOnLock(isPresented: Binding<Bool>) -> some View {
        modifier(DismissOnLock(isPresented: isPresented))
    }
}

// MARK: - RestoreOnUnlock (Phase 5)

/// Apply to a view that hosts a `.sheet(item:)` or `.sheet(isPresented:)`
/// that should re-present after unlock with the same selection. Snapshots
/// the binding's current value on lock, sets it to nil/false to dismiss,
/// and re-assigns it on unlock.
///
/// Phase 5 wires this into picker/review sheets. Defined here so Phase 4
/// can ship without dragging the Phase 5 surface area along.
struct RestoreOnUnlock<Item>: ViewModifier where Item: Identifiable {

    @Binding var item: Item?

    @State private var registration: ModalCoordinator.Registration?

    func body(content: Content) -> some View {
        content
            .onChange(of: item?.id, initial: true) { _, newID in
                if newID != nil {
                    // Capture the *current* item by value so the restore
                    // closure replays the correct selection even if the
                    // user navigated away after lock fired.
                    let snapshot = item
                    let reg = ModalCoordinator.shared.registerRestorable(
                        dismiss: { item = nil },
                        restore: { item = snapshot }
                    )
                    registration = reg
                } else {
                    registration?.unregister()
                    registration = nil
                }
            }
    }
}

/// Boolean variant for `.sheet(isPresented:)`. Re-presents the sheet on
/// unlock — useful when the sheet's content is parameter-less (e.g.,
/// "compose new message" with no preselected target).
struct RestoreOnUnlockBool: ViewModifier {

    @Binding var isPresented: Bool

    @State private var registration: ModalCoordinator.Registration?

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented, initial: true) { _, newValue in
                if newValue {
                    let reg = ModalCoordinator.shared.registerRestorable(
                        dismiss: { isPresented = false },
                        restore: { isPresented = true }
                    )
                    registration = reg
                } else {
                    registration?.unregister()
                    registration = nil
                }
            }
    }
}

extension View {
    func restoreOnUnlock<Item: Identifiable>(item: Binding<Item?>) -> some View {
        modifier(RestoreOnUnlock(item: item))
    }

    func restoreOnUnlock(isPresented: Binding<Bool>) -> some View {
        modifier(RestoreOnUnlockBool(isPresented: isPresented))
    }
}
