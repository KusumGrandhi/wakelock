import AppKit
import ServiceManagement

// Used by scripts/uninstall.sh; handled before anything touches pmset.
if CommandLine.arguments.contains("--unregister-login-item") {
    try? SMAppService.mainApp.unregister()
    exit(0)
}

// Single instance: a second copy would reset disablesleep under the first one.
if let bundleID = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
       .contains(where: { $0.processIdentifier != getpid() }) {
    exit(0)
}

CrashGuard.install()
Watchdog.spawn()
WakelockApp.main()
