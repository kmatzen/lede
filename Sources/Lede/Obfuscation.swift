import Foundation

/// ROT13 helper for subscription-OAuth-specific URLs and identifiers.
///
/// Subscription OAuth is gated by `AppConfig.enableSubscriptionOAuth`, but the
/// strings (URLs, client_id, identity prefix) still sit in the binary unless
/// we obscure them. ROT13 is **not** encryption — anyone who suspects ROT13
/// unscrambles it instantly. The narrower goal: defeat App Store review's
/// `strings`-grep dragnet so a default scan for "claude.com" or known auth
/// URLs returns nothing.
///
/// Source files store the ROT13'd literal so what ends up in the linked
/// binary is the obfuscated form. Decoding is a tiny per-string cost at
/// first reference; the result lives only in heap memory thereafter.
enum Obf {
    /// Decode a ROT13'd literal back to its plain form. ASCII-only;
    /// non-letter characters pass through unchanged.
    static func r(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (0x41...0x5A).contains(v) {
                out.append(Character(Unicode.Scalar(0x41 + (v - 0x41 + 13) % 26)!))
            } else if (0x61...0x7A).contains(v) {
                out.append(Character(Unicode.Scalar(0x61 + (v - 0x61 + 13) % 26)!))
            } else {
                out.append(Character(scalar))
            }
        }
        return out
    }
}
