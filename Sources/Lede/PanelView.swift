import SwiftUI

struct PanelView: View {
    @ObservedObject var engine: CoreEngine
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
    }

    @AppStorage(PinnedPanel.pinDefaultsKey) private var pinned = false

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.badge")
            Text("Lede").font(.system(size: 13, weight: .semibold))
            Spacer()
            if engine.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await engine.refresh(force: true) }
            } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(engine.isRefreshing)
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh now (⌘R)")
                .accessibilityLabel("Refresh now")

            Button {
                pinned.toggle()
                // Let the menu bar controller know so it can drop / reinstall
                // the outside-click auto-hide without waiting for a reopen.
                NotificationCenter.default.post(name: .ledePinStateChanged, object: nil)
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .foregroundStyle(pinned ? .orange : .secondary)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("p", modifiers: .command)
            .help(pinned ? "Unpin (⌘P)" : "Pin (⌘P)")
            .accessibilityLabel(pinned ? "Unpin panel" : "Pin panel")

            Button {
                onOpenSettings()
            } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .keyboardShortcut(",", modifiers: .command)
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let digest = engine.digest, !digest.items.isEmpty {
            digestList(digest)
        } else if engine.isRefreshing {
            centered { Text("Refreshing…").foregroundStyle(.secondary) }
        } else if let err = engine.lastError {
            errorView(err)
        } else if !engine.hasClaudeCreds() || !engine.hasAnySource() {
            unconfigured
        } else {
            centered { Text("No notifications.").foregroundStyle(.secondary) }
        }
    }

    private func digestList(_ d: Digest) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let s = d.synthesis {
                    synthesisBox(s)
                }
                ForEach(PriorityTier.all) { tier in
                    let items = d.items.filter { tier.range.contains($0.score) }
                    if !items.isEmpty {
                        TierSection(tier: tier, items: items, onDismiss: dismiss)
                    }
                }
                footer(d)
            }
            .padding(10)
        }
    }

    private func dismiss(_ hash: String) {
        Task { await engine.dismiss(hash) }
    }

    private func synthesisBox(_ s: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Briefing", systemImage: "sparkles")
                .font(.caption).foregroundStyle(.secondary)
            Text(s)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func footer(_ d: Digest) -> some View {
        HStack {
            Spacer()
            Text("Updated \(d.generatedAt, style: .relative) ago")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer()
        }.padding(.top, 4)
    }

    private func centered<V: View>(@ViewBuilder _ view: () -> V) -> some View {
        VStack { Spacer(); view(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ err: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Something went wrong", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(err).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var unconfigured: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Welcome").font(.title3).bold()
            Text("Connect at least one notification source and set up Claude to start.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") { onOpenSettings() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Priority tiers

struct PriorityTier: Identifiable {
    let name: String
    let range: ClosedRange<Int>
    let color: Color
    let defaultExpanded: Bool

    var id: String { name }

    static let all: [PriorityTier] = [
        .init(name: "Critical", range: 9...10, color: .red, defaultExpanded: true),
        .init(name: "High",     range: 6...8,  color: .orange, defaultExpanded: true),
        .init(name: "Medium",   range: 4...5,  color: .yellow, defaultExpanded: false),
        .init(name: "Low",      range: 0...3,  color: .gray, defaultExpanded: false),
    ]
}

private struct TierSection: View {
    let tier: PriorityTier
    let items: [Digest.Item]
    let onDismiss: (String) -> Void

    @AppStorage private var expanded: Bool

    init(tier: PriorityTier, items: [Digest.Item], onDismiss: @escaping (String) -> Void) {
        self.tier = tier
        self.items = items
        self.onDismiss = onDismiss
        self._expanded = AppStorage(
            wrappedValue: tier.defaultExpanded,
            "panel.tier.\(tier.name).expanded"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { expanded.toggle() }) {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Circle().fill(tier.color).frame(width: 7, height: 7)
                    Text(tier.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text("\(items.count)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 6) {
                    ForEach(items) { item in
                        DigestRowView(item: item, onDismiss: { onDismiss(item.contentHash) })
                    }
                }
                .padding(.leading, 2)
            }
        }
    }
}
