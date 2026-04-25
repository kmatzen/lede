import SwiftUI

struct DigestRowView: View {
    let item: Digest.Item
    /// When true, show the account label after the source name. Caller passes
    /// true only for sources where the user has multiple accounts connected,
    /// so single-account users see no extra clutter.
    var showAccountLabel: Bool = false
    var onDismiss: (() -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            scorePill
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text(item.source.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if showAccountLabel, let label = item.accountLabel {
                        Text("· \(label)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let sender = item.sender {
                        Text("· \(sender)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    Text(item.receivedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(item.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                if !item.reason.isEmpty {
                    Text(item.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { open() }

            if onDismiss != nil {
                Button(action: { onDismiss?() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
                .opacity(hovering ? 1 : 0)
                .animation(.easeInOut(duration: 0.12), value: hovering)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .contextMenu {
            if let onDismiss {
                Button("Dismiss", action: onDismiss)
            }
            if item.url != nil {
                Button("Open", action: open)
            }
        }
    }

    private var icon: String {
        switch item.source {
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .gmail: return "envelope"
        case .slack: return "number"
        case .outlook: return "envelope.badge"
        case .calendar: return "calendar"
        }
    }

    private var scorePill: some View {
        Text("\(item.score)")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .frame(width: 22, height: 22)
            .background(color.opacity(0.25), in: Circle())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch item.score {
        case 9...: return .red
        case 7...: return .orange
        case 5...: return .yellow
        case 3...: return .blue
        default: return .secondary
        }
    }

    private func open() {
        if let url = item.url { NSWorkspace.shared.open(url) }
    }
}
