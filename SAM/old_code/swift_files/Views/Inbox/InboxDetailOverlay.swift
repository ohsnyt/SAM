import SwiftUI

struct OverlayArea: View {
    @Binding var alertMessage: String?
    @Binding var pendingContactPrompt: InboxDetailView.PendingContactPrompt?

    let onAddContact: (InboxDetailView.PendingContactPrompt) -> Void
    let onDismissPrompt: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            if let message = alertMessage {
                ToastView(message: message)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation { alertMessage = nil }
                        }
                    }
            }
            if let prompt = pendingContactPrompt {
                ContactPromptView(prompt: prompt, onAdd: { onAddContact(prompt) }, onDismiss: onDismissPrompt)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}
