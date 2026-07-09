import SwiftUI

/// Renders one MCP elicitation request as a read-only notification: the server's message
/// and the fields it wants, shown for context. You fill the form in the terminal; the
/// footer brings it forward.
struct ElicitationItemView: View {
    @ObservedObject var item: PendingItem
    let request: ElicitationRequest
    let queue: QueueStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let server = request.serverName, !server.isEmpty {
                Text(server)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            Text(request.message)
                .font(.subheadline.weight(.medium))

            if !request.fields.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(request.fields) { field in
                        fieldRow(field)
                    }
                }
            }

            AttentionFooter(item: item, queue: queue)
        }
        .padding(.vertical, 4)
    }

    private func fieldRow(_ field: ElicitationField) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "square.dashed")
                .font(.caption2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(field.required ? "\(field.title) *" : field.title)
                    .font(.caption.weight(.medium))
                if let description = field.description, !description.isEmpty {
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}
