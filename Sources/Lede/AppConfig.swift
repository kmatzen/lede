import Foundation

/// Optional config read from `~/Library/Application Support/Lede/config.json` once at launch.
///
/// Currently exposes a single knob: `enableSubscriptionOAuth`. Default is
/// `false`, which hides the Claude Pro/Max sign-in UI and skips the
/// subscription token path in the engine. Drop a file like:
///
///     {
///       "enableSubscriptionOAuth": true
///     }
///
/// to opt in. The config is cached at first read; restart Lede to apply changes.
struct AppConfig: Decodable {
    var enableSubscriptionOAuth: Bool = false

    private enum CodingKeys: String, CodingKey {
        case enableSubscriptionOAuth
    }

    static let shared: AppConfig = load()

    private static func load() -> AppConfig {
        let fm = FileManager.default
        guard let support = try? fm.url(for: .applicationSupportDirectory,
                                        in: .userDomainMask,
                                        appropriateFor: nil, create: false) else {
            return AppConfig()
        }
        let url = support
            .appendingPathComponent("Lede", isDirectory: true)
            .appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url) else { return AppConfig() }
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            Log.warn("config.json present but unparsable: \(error.localizedDescription)")
            return AppConfig()
        }
    }
}
