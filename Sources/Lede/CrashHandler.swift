import Foundation

/// Captures uncaught Objective-C exceptions and the most common fatal POSIX
/// signals into the app's log file so users can attach it to bug reports.
///
/// We intentionally don't try to gracefully continue execution — by the time
/// these handlers fire, the process is in an unrecoverable state. Goal is
/// just to leave a breadcrumb before macOS terminates us.
enum CrashHandler {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true

        NSSetUncaughtExceptionHandler { exception in
            let symbols = exception.callStackSymbols.joined(separator: "\n")
            let reason = exception.reason ?? "(no reason)"
            Log.error("UNCAUGHT NSException: \(exception.name.rawValue): \(reason)\n\(symbols)")
        }

        // Signal handlers must be a non-capturing C function pointer.
        // Best-effort log + restore default handler + re-raise so the OS
        // produces a normal crash report.
        for sig: Int32 in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGPIPE] {
            signal(sig, signalHandler)
        }
    }
}

private func signalHandler(_ sig: Int32) {
    let name: String
    switch sig {
    case SIGABRT: name = "SIGABRT"
    case SIGILL:  name = "SIGILL"
    case SIGSEGV: name = "SIGSEGV"
    case SIGFPE:  name = "SIGFPE"
    case SIGBUS:  name = "SIGBUS"
    case SIGPIPE: name = "SIGPIPE"
    default:      name = "SIG\(sig)"
    }
    Log.error("FATAL SIGNAL: \(name) (\(sig))")
    signal(sig, SIG_DFL)
    raise(sig)
}
