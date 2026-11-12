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

extension Notification.Name {
    static let macCareOpenHelp = Notification.Name("MacCareOpenHelp")
}

struct MacCareGUIApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("MacCare — macOS System Health, Cleanup & Security") {
            ContentView()
                .frame(minWidth: 940, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .help) {
                Button("MacCare Module Guide & Help...") {
                    NotificationCenter.default.post(name: .macCareOpenHelp, object: nil)
                }
                .keyboardShortcut("/", modifiers: [.command, .shift])

                Divider()

                Button("MacCare GitHub Repository...") {
                    if let url = URL(string: "https://github.com/ChipGillespie/MacCare") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button("Search or Report an Issue on GitHub...") {
                    if let url = URL(string: "https://github.com/ChipGillespie/MacCare/issues") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
