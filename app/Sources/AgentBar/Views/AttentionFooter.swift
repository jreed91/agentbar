import SwiftUI

/// Footer shown under attention items (questions, permissions, MCP input requests).
/// AgentBar is notify-only, so there is nothing to submit here — the actions bring your
/// terminal forward so you can answer the prompt there, or dismiss the notification.
struct AttentionFooter: View {
    @ObservedObject var item: PendingItem
    let queue: QueueStore

    var body: some View {
        HStack(spacing: 8) {
            Text("Answer in your terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Focus terminal") { TerminalFocus.focus() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Dismiss") { queue.dismiss(item) }
                .controlSize(.small)
        }
    }
}
