import SwiftUI
import AppKit

/// Headless renderer that produces a PNG of the panel with curated mock
/// data — used to ship a real "screenshot" with the website without needing
/// a real account / live data hooked up.
///
/// Invoked via `Lede --screenshot <path>` (handled in LedeApp.main). Uses
/// SwiftUI's ImageRenderer (macOS 13+) so no GUI orchestration is needed.
///
/// Note: we do **not** reuse PanelView itself. PanelView reads from a live
/// `CoreEngine` ObservableObject and uses `.regularMaterial` for its
/// background, neither of which plays nicely with ImageRenderer (the
/// material renders transparent without a window context, and observed
/// changes set right before render can fail to propagate). Instead we
/// hand-roll a static layout using the same `TierSection` + `DigestRowView`
/// the live app uses, so the visual is identical down to the row chrome.
@MainActor
enum Screenshot {

    static func render(to outURL: URL) {
        let size = NSSize(width: 420, height: 600)
        let engine = CoreEngine(storage: Storage.shared, autoload: false)
        engine.digest = mockDigest()
        engine.lastRefreshed = Date().addingTimeInterval(-30)
        engine.sourceStates = [
            .github:   SourceState(lastFetchedAt: Date(), lastItemCount: 3, lastError: nil),
            .gmail:    SourceState(lastFetchedAt: Date(), lastItemCount: 2, lastError: nil),
            .slack:    SourceState(lastFetchedAt: Date(), lastItemCount: 1, lastError: nil),
            .calendar: SourceState(lastFetchedAt: Date(), lastItemCount: 1, lastError: nil),
        ]
        let view = PanelView(engine: engine, onOpenSettings: {})
            .frame(width: size.width, height: size.height)
            .preferredColorScheme(.dark)

        // Hosting in a real (offscreen) NSWindow forces a full AppKit layout
        // pass — far more reliable than ImageRenderer for views that read
        // from environment / use materials / depend on hosting view chrome.
        let host = NSHostingController(rootView: view)
        host.view.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = host
        // Position offscreen so this never flashes on the user's display.
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()

        // Let layout + image loading settle.
        for _ in 0..<6 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        let v = host.view
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else {
            FileHandle.standardError.write(Data("error: bitmap rep failed\n".utf8))
            window.close()
            return
        }
        rep.size = v.bounds.size
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("error: png encode failed\n".utf8))
            window.close()
            return
        }

        do {
            try png.write(to: outURL, options: .atomic)
            FileHandle.standardOutput.write(Data("✓ Wrote \(outURL.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("error: write failed — \(error)\n".utf8))
        }
        window.close()
    }

    private static func mockDigest() -> Digest {
        let now = Date()
        let items: [Digest.Item] = [
            .init(contentHash: "mock-1", source: .slack,
                  title: "#eng-alerts", sender: "Sarah Chen",
                  url: nil, receivedAt: now.addingTimeInterval(-2 * 60),
                  score: 9, summary: "@you: staging is throwing 502s, can someone look",
                  reason: "direct mention, ongoing incident"),
            .init(contentHash: "mock-2", source: .github,
                  title: "acme/api: Migrate auth to passkeys", sender: "marcus",
                  url: nil, receivedAt: now.addingTimeInterval(-14 * 60),
                  score: 8, summary: "PR review requested",
                  reason: "review requested by teammate"),
            .init(contentHash: "mock-3", source: .gmail,
                  title: "Quick Q before your 2pm", sender: "Sarah Chen",
                  url: nil, receivedAt: now.addingTimeInterval(-38 * 60),
                  score: 7, summary: "Got 5 min before our 1:1? Want to align on Q4 plan first.",
                  reason: "from manager, time-bound"),
            .init(contentHash: "mock-4", source: .calendar,
                  title: "Design review — Lede dashboard", sender: "calendar",
                  url: nil, receivedAt: now.addingTimeInterval(45 * 60),
                  score: 6, summary: "Event in 45 min · with 4 attendees",
                  reason: "you haven't responded yet"),
            .init(contentHash: "mock-5", source: .github,
                  title: "acme/api: CI failed on lede-1.0.0", sender: "github-actions",
                  url: nil, receivedAt: now.addingTimeInterval(-90 * 60),
                  score: 5, summary: "Test suite failing on main after passkeys merge",
                  reason: "your PR broke tests"),
            .init(contentHash: "mock-6", source: .gmail,
                  title: "Stripe receipt — Anthropic API", sender: "Stripe",
                  url: nil, receivedAt: now.addingTimeInterval(-3 * 3600),
                  score: 2, summary: "Payment of $4.12 to Anthropic processed.",
                  reason: "automated receipt"),
            .init(contentHash: "mock-7", source: .gmail,
                  title: "GitHub Weekly Digest", sender: "GitHub",
                  url: nil, receivedAt: now.addingTimeInterval(-5 * 3600),
                  score: 1, summary: "Top trending repos this week",
                  reason: "newsletter"),
        ]
        return Digest(
            generatedAt: now,
            items: items,
            synthesis: "Sarah pinged you in #eng-alerts about a staging outage — that's the priority. Two PR reviews and a meeting in 45 minutes after that. The rest can wait."
        )
    }
}

