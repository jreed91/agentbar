import SwiftUI

/// Renders one permission request: the tool name, its input in a scrollable monospaced
/// code block, and Allow / Deny(+optional message) / decide-in-terminal actions.
struct PermissionItemView: View {
    @ObservedObject var item: PendingItem
    let toolName: String
    let detail: String
    let queue: QueueStore

    @State private var denyMessage: String = ""

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

            TextField("Optional reason for denying…", text: $denyMessage)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Allow") { queue.allowPermission(item: item) }
                    .buttonStyle(.borderedProminent)
                Button("Deny") { queue.denyPermission(item: item, message: denyMessage) }
                Spacer()
                Button("Decide in terminal") { queue.passthrough(item: item) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}
