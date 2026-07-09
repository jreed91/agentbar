import SwiftUI

/// Renders one permission request as a read-only notification: the tool name and its
/// input in a scrollable monospaced code block so you can see what Claude wants to do.
/// You allow or deny in the terminal; the footer just brings it forward.
struct PermissionItemView: View {
    @ObservedObject var item: PendingItem
    let toolName: String
    let detail: String
    let queue: QueueStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(toolName)
                .font(.subheadline.weight(.semibold))

            ScrollView {
                Text(detail.isEmpty ? "(no input)" : detail)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(maxHeight: 140)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            AttentionFooter(item: item, queue: queue)
        }
        .padding(.vertical, 4)
    }
}
