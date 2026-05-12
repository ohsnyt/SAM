//
//  ManagedSheetModifier.swift
//  SAM
//
//  Drop-in replacement for `.sheet(isPresented:)` / `.sheet(item:)` that
//  routes every presentation through `ModalCoordinator`'s presentation
//  arbiter. SwiftUI on macOS can only show one sheet per window at a
//  time, so when two `.sheet` bindings flip true at different hierarchy
//  levels SwiftUI dismisses the first to present the second (the bug
//  Sarah hit on Apr 24 — LinkedIn import sheet vanished when a post-call
//  capture sheet appeared).
//
//  This modifier ensures **only one sheet's underlying binding is ever
//  `true` at a time**, app-wide. Concurrent requests queue. Higher-
//  priority requests with `.replaceLowerPriority` policy displace
//  lower-priority active sheets; the displaced sheet re-presents
//  automatically when the displacer dismisses.
//
//  Lock/unlock is handled transparently: the coordinator dismisses the
//  active managed sheet on lock and restores it on unlock for
//  `.coaching`+ priorities. Callers don't need to additionally apply
//  `restoreOnUnlock`.
//
//  Usage:
//  ```
//  .managedSheet(
//      isPresented: $showSomething,
//      priority: .userInitiated,
//      identifier: "settings.something"
//  ) { SomethingView() }
//
//  .managedSheet(
//      item: $capturePayload,
//      priority: .opportunistic,
//      identifier: "post-meeting-capture"
//  ) { payload in PostMeetingCaptureView(payload: payload) }
//  ```
//

import SwiftUI

// MARK: - Internal State Box
//
// Holds non-reactive per-view state that must survive across SwiftUI
// struct re-creations and be captured-by-reference into closures stored
// on the coordinator. We don't use @StateObject + ObservableObject here
// because none of these fields need to drive SwiftUI re-renders — the
// only SwiftUI-reactive piece (the sheet's actual visibility) lives in
// a separate @State Bool. A plain class kept in @State gives us a
// stable reference cell without the property-wrapper confusion that
// arises around @Published vs non-@Published members on an
// ObservableObject.

@MainActor
private final class ManagedSheetBox {
    var token: ModalCoordinator.PresentationToken?

    /// Set true by the coordinator's `dismissActive` closure before it
    /// flips the visibility binding off. Tells the visibility-change
    /// handler "this dismissal is temporary; don't release the token or
    /// sync the caller's binding to false — the coordinator will re-
    /// present when the queue advances or the app unlocks." Reset to
    /// false after each dismissal we observe.
    var coordinatorDrivenDismissal: Bool = false
}

// MARK: - isPresented Variant

private struct ManagedSheetIsPresented<SheetContent: View>: ViewModifier {

    @Binding var isPresented: Bool
    let priority: ModalCoordinator.Priority
    let policy: ModalCoordinator.ConflictPolicy
    let identifier: String
    let sheetContent: () -> SheetContent

    /// SwiftUI-reactive visibility. The coordinator drives this directly
    /// via the closures passed into `requestPresentation`. The caller's
    /// `isPresented` binding is the *request* signal; this is the
    /// actual on-screen state.
    @State private var isShowing: Bool = false

    /// Non-reactive bookkeeping (token + displacement flag). Class so
    /// the coordinator's closures capture it by reference and observe
    /// the live values when they fire.
    @State private var box = ManagedSheetBox()

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isShowing, content: sheetContent)
            .onChange(of: isPresented, initial: true) { _, newValue in
                if newValue {
                    guard box.token == nil else { return }
                    let capturedBox = box
                    box.token = ModalCoordinator.shared.requestPresentation(
                        identifier: identifier,
                        priority: priority,
                        policy: policy,
                        present: {
                            capturedBox.coordinatorDrivenDismissal = false
                            isShowing = true
                        },
                        dismissActive: {
                            capturedBox.coordinatorDrivenDismissal = true
                            isShowing = false
                        }
                    )
                } else {
                    // Caller withdrew the request (set isPresented to
                    // false before or during presentation). Release the
                    // token; dismiss the sheet if it was up. This is a
                    // real dismissal, not a displacement.
                    box.token?.dismissed()
                    box.token = nil
                    if isShowing {
                        box.coordinatorDrivenDismissal = false
                        isShowing = false
                    }
                }
            }
            .onChange(of: isShowing) { oldValue, newValue in
                guard oldValue && !newValue else { return }
                // Sheet just went off-screen. Two cases:
                //
                // 1. Coordinator-driven: it called dismissActive to
                //    make room for a higher-priority request, or
                //    because the app is locking. The token is still
                //    ours and the request is still pending. Don't
                //    sync the caller's binding — they still want this
                //    presented, and the coordinator will re-fire
                //    `present` later.
                //
                // 2. User-driven: ESC, click outside, X button. The
                //    caller's binding needs to flip to false so they
                //    observe the dismissal, and the token must release
                //    to free the coordinator's slot.
                if box.coordinatorDrivenDismissal {
                    box.coordinatorDrivenDismissal = false
                    return
                }
                box.token?.dismissed()
                box.token = nil
                if isPresented {
                    isPresented = false
                }
            }
    }
}

// MARK: - item Variant

private struct ManagedSheetItem<Item: Identifiable, SheetContent: View>: ViewModifier {

    @Binding var item: Item?
    let priority: ModalCoordinator.Priority
    let policy: ModalCoordinator.ConflictPolicy
    let identifier: String
    let sheetContent: (Item) -> SheetContent

    /// Mirrors `item` for the actual SwiftUI sheet. Separate so the
    /// coordinator can hide the sheet (set to nil) without nilling the
    /// caller's `item` binding during a transient displacement.
    @State private var presentedItem: Item?

    @State private var box = ManagedSheetBox()

    func body(content: Content) -> some View {
        content
            .sheet(item: $presentedItem, content: sheetContent)
            .onChange(of: item?.id, initial: true) { _, _ in
                let snapshot = item
                if let snapshot {
                    if box.token == nil {
                        let capturedBox = box
                        box.token = ModalCoordinator.shared.requestPresentation(
                            identifier: identifier,
                            priority: priority,
                            policy: policy,
                            present: {
                                capturedBox.coordinatorDrivenDismissal = false
                                presentedItem = snapshot
                            },
                            dismissActive: {
                                capturedBox.coordinatorDrivenDismissal = true
                                presentedItem = nil
                            }
                        )
                    } else if presentedItem != nil {
                        // Already presenting — caller swapped to a
                        // newer payload. Update the visible sheet's
                        // item rather than tearing down and re-
                        // queueing.
                        presentedItem = snapshot
                    }
                } else {
                    box.token?.dismissed()
                    box.token = nil
                    if presentedItem != nil {
                        box.coordinatorDrivenDismissal = false
                        presentedItem = nil
                    }
                }
            }
            .onChange(of: presentedItem?.id) { oldValue, newValue in
                guard oldValue != nil && newValue == nil else { return }
                if box.coordinatorDrivenDismissal {
                    box.coordinatorDrivenDismissal = false
                    return
                }
                box.token?.dismissed()
                box.token = nil
                if item != nil {
                    item = nil
                }
            }
    }
}

// MARK: - Public API

extension View {

    /// Presents `content` as a sheet whose presentation is serialized
    /// app-wide by `ModalCoordinator`. See `ManagedSheetModifier.swift`
    /// header for rationale.
    ///
    /// - Parameters:
    ///   - isPresented: Caller's binding. Set to `true` to request
    ///     presentation; the coordinator decides when to actually show.
    ///     The modifier sets it back to `false` when the sheet truly
    ///     dismisses (not on transient displacement).
    ///   - priority: How urgent this sheet is. See `ModalCoordinator.Priority`.
    ///   - policy: How to handle conflicts. Defaults to `.queue`.
    ///   - identifier: Stable string for logging and diagnostics.
    ///   - content: Sheet body.
    func managedSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        priority: ModalCoordinator.Priority,
        policy: ModalCoordinator.ConflictPolicy = .queue,
        identifier: String,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(ManagedSheetIsPresented(
            isPresented: isPresented,
            priority: priority,
            policy: policy,
            identifier: identifier,
            sheetContent: content
        ))
    }

    /// Item variant. Same semantics as `managedSheet(isPresented:...)`.
    /// The caller's `item` binding only goes to nil on a real
    /// dismissal, not during displacement.
    func managedSheet<Item: Identifiable, SheetContent: View>(
        item: Binding<Item?>,
        priority: ModalCoordinator.Priority,
        policy: ModalCoordinator.ConflictPolicy = .queue,
        identifier: String,
        @ViewBuilder content: @escaping (Item) -> SheetContent
    ) -> some View {
        modifier(ManagedSheetItem(
            item: item,
            priority: priority,
            policy: policy,
            identifier: identifier,
            sheetContent: content
        ))
    }
}
