import Cocoa

@main
@MainActor
enum LedeApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only; no Dock icon
        app.run()
    }
}
