import SwiftUI
import AppKit

@main
struct MacCareApp {
    static func main() async {
        if CommandLine.arguments.contains("--background-scan") {
            await SystemScanner.runBackgroundScanAndNotify()
            exit(0)
        } else {
            MacCareGUIApp.main()
        }
    }
}

struct MacCareGUIApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("MacCare — MacBook Air Health, Cleanup & Security") {
            ContentView()
                .frame(minWidth: 940, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
    }
}
