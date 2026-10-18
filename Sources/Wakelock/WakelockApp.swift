import AppKit
import SwiftUI

struct WakelockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(controller: appDelegate.controller)
        } label: {
            MenuBarLabel(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = WakeController()
    private var server: LeaseServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()

        let server = LeaseServer(path: Paths.socket) { [weak controller] line in
            controller?.handle(line: line) ?? "err shutting down"
        }
        do {
            try server.start()
            self.server = server
        } catch {
            controller.socketError = "Lease socket unavailable: \(error)"
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        controller.shutdown()
    }
}
