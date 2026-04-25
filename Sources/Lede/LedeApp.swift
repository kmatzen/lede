import Cocoa

@main
@MainActor
enum LedeApp {
    static func main() {
        // Headless screenshot mode for the website. `Lede --screenshot path.png`
        // renders PanelView with curated mock data and exits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--screenshot"), i + 1 < args.count {
            // ImageRenderer needs an active NSApplication for AppKit-backed
            // SwiftUI primitives; .accessory keeps it out of the Dock.
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Screenshot.render(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only; no Dock icon
        app.run()
    }
}
