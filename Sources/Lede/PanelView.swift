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
            Button {
                onOpenSettings()
            } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
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
            VStack(alignment: .leading, spacing: 8) {
                if let s = d.synthesis {
                    synthesisBox(s)
                }
                ForEach(d.items) { item in
                    DigestRowView(item: item)
                }
                footer(d)
            }
            .padding(10)
        }
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
