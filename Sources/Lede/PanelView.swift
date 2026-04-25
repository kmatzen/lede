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
            centered {
                ProgressView().controlSize(.small)
                Text("Catching up…").foregroundStyle(.secondary).padding(.top, 4)
            }
        } else if let err = engine.lastError {
            errorView(err)
        } else if !engine.hasClaudeCreds() || !engine.hasAnySource() {
            unconfigured
        } else {
            caughtUp
        }
    }

    /// Replaces the bare "No notifications." text. If sources have run at
    /// least once and returned 0 unread, the user is genuinely caught up,
    /// which is a small win worth marking as such.
    private var caughtUp: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 32))
                .foregroundStyle(.green.opacity(0.7))
            Text("You're caught up.")
                .font(.system(size: 14, weight: .semibold))
            if let last = engine.lastRefreshed {
                Text("Last checked \(last, style: .relative) ago")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            sourceCountsLine
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Aggregates per-(account, source) state down to one entry per Source,
    /// summing item counts across accounts. Empty if no source has fetched.
    private var aggregatedSourceCounts: [(Source, Int)] {
        var totals: [Source: Int] = [:]
        for (key, state) in engine.sourceStates {
            guard state.lastFetchedAt != nil else { continue }
            // key = "<provider>:<accountID>:<source.rawValue>"
            guard let lastSegment = key.split(separator: ":").last,
                  let s = Source(rawValue: String(lastSegment)) else { continue }
            totals[s, default: 0] += state.lastItemCount
        }
        return Source.allCases.compactMap { s in
            guard let n = totals[s] else { return nil }
            return (s, n)
        }
    }

    /// One-line digest of how each source is doing — visible only in the
    /// caught-up state, where the user might wonder "did anything actually run?"
    /// Sums counts across all accounts of a source.
    @ViewBuilder
    private var sourceCountsLine: some View {
        let entries = aggregatedSourceCounts
        if !entries.isEmpty {
            HStack(spacing: 10) {
                ForEach(entries, id: \.0) { source, count in
                    HStack(spacing: 3) {
                        Text(source.displayName).foregroundStyle(.secondary)
                        Text("\(count)").foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
            }
            .font(.caption2)
            .padding(.bottom, 12)
        }
    }

    /// Sources where the user has 2+ accounts connected — those rows show an
    /// account label so the user can tell "personal Gmail" from "work Gmail".
    private var multiAccountSources: Set<Source> {
        var counts: [Source: Int] = [:]
        for account in engine.accounts {
            for source in account.provider.sources {
                counts[source, default: 0] += 1
            }
        }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    private func digestList(_ d: Digest) -> some View {
        let multi = multiAccountSources
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let s = d.synthesis {
                    synthesisBox(s)
                }
                ForEach(PriorityTier.all) { tier in
                    let items = d.items.filter { tier.range.contains($0.score) }
                    if !items.isEmpty {
                        TierSection(tier: tier, items: items,
                                    multiAccountSources: multi, onDismiss: dismiss)
                    }
                }
                footer(d)
            }
            .padding(10)
            .animation(.easeInOut(duration: 0.18), value: d.items.map(\.contentHash))
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
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to Lede")
                .font(.title2).bold()
            Text("Lede watches your inboxes and pulls the few things that actually need your attention to the top.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                stepRow(
                    number: 1,
                    done: engine.hasClaudeCreds(),
                    title: "Connect Claude",
                    detail: "So Lede can score and summarize your messages."
                )
                stepRow(
                    number: 2,
                    done: engine.hasAnySource(),
                    title: "Connect at least one source",
                    detail: "Gmail, GitHub, Slack, or Outlook."
                )
                stepRow(
                    number: 3,
                    done: false,
                    title: "Click the bell anytime",
                    detail: "Items show up here, ranked by what to look at first."
                )
            }
            .padding(.vertical, 6)

            Button("Open Settings") { onOpenSettings() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func stepRow(number: Int, done: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.secondary.opacity(0.15))
                    .frame(width: 22, height: 22)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

struct TierSection: View {
    let tier: PriorityTier
    let items: [Digest.Item]
    let multiAccountSources: Set<Source>
    let onDismiss: (String) -> Void

    @AppStorage private var expanded: Bool

    init(tier: PriorityTier,
         items: [Digest.Item],
         multiAccountSources: Set<Source> = [],
         onDismiss: @escaping (String) -> Void) {
        self.tier = tier
        self.items = items
        self.multiAccountSources = multiAccountSources
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
                        DigestRowView(
                            item: item,
                            showAccountLabel: multiAccountSources.contains(item.source),
                            onDismiss: { onDismiss(item.contentHash) }
                        )
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .opacity.combined(with: .scale(scale: 0.98))
                            ))
                    }
                }
                .padding(.leading, 2)
            }
        }
    }
}
