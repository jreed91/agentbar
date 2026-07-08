import SwiftUI

/// The popover content: a header with the pending count and a Settings gear, then the
/// pending items grouped by session (labelled with the project directory), newest first.
struct QueueView: View {
    @ObservedObject private var queue = AppState.shared.queue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if queue.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(sessions, id: \.sessionID) { group in
                            sessionSection(group)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 380)
        .frame(minHeight: 120, maxHeight: 520)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.fill")
            Text("AgentBar").font(.headline)
            Spacer()
            if queue.pendingCount > 0 {
                Text("\(queue.pendingCount) pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("All caught up")
                .font(.headline)
            Text("No pending questions or permissions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    // MARK: - Grouping

    private struct SessionGroup {
        let sessionID: String
        let cwd: String
        let items: [PendingItem]
    }

    private var sessions: [SessionGroup] {
        let grouped = Dictionary(grouping: queue.items, by: { $0.sessionID })
        return grouped.map { key, value in
            let sorted = value.sorted { $0.createdAt > $1.createdAt }
            return SessionGroup(sessionID: key, cwd: sorted.first?.cwd ?? "", items: sorted)
        }
        .sorted {
            ($0.items.first?.createdAt ?? .distantPast) > ($1.items.first?.createdAt ?? .distantPast)
        }
    }

    @ViewBuilder
    private func sessionSection(_ group: SessionGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(projectName(group.cwd))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .help(group.cwd)
            ForEach(group.items) { item in
                itemView(item)
                Divider()
            }
        }
    }

    @ViewBuilder
    private func itemView(_ item: PendingItem) -> some View {
        switch item.kind {
        case .question(let questions):
            QuestionItemView(item: item, questions: questions, queue: queue)
        case .permission(let toolName, let detail):
            PermissionItemView(item: item, toolName: toolName, detail: detail, queue: queue)
        case .info(let title, let body):
            infoRow(item: item, title: title, body: body)
        }
    }

    private func infoRow(item: PendingItem, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(body).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                queue.dismiss(item)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func projectName(_ cwd: String) -> String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}
