import SwiftUI
import AppKit

/// Custom borderless full-screen window that can become key so it captures keyboard and mouse events while cleaning.
final class ScreenCleanerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class ScreenCleanerManager: ObservableObject {
    @Published var isActive: Bool = false
    @Published var remainingSeconds: Int = 120
    @Published var selectedDurationSeconds: Int = 120 // Default: 2 minutes (120s)
    @Published var showMinimalHUD: Bool = true
    @Published var statusMessage: String?

    private var overlayWindows: [NSWindow] = []
    private var countdownTimer: Timer?
    private var eventMonitor: Any?

    var formattedRemainingTime: String {
        let mins = remainingSeconds / 60
        let secs = remainingSeconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    func startCleaning(durationSeconds: Int? = nil) {
        guard !isActive else { return }
        let total = durationSeconds ?? selectedDurationSeconds
        remainingSeconds = total
        isActive = true
        statusMessage = nil

        // Hide Menu Bar and Dock while cleaning so edges can be wiped safely
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        NSApp.activate(ignoringOtherApps: true)

        // Create a pure black full-screen window on every connected display
        overlayWindows.removeAll()
        for (index, screen) in NSScreen.screens.enumerated() {
            let window = ScreenCleanerWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = .screenSaver
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.setFrame(screen.frame, display: true)

            let overlayView = ScreenCleanerOverlayView(
                manager: self,
                isPrimaryDisplay: (index == 0)
            )
            window.contentView = NSHostingView(rootView: overlayView)
            window.makeKeyAndOrderFront(nil)
            overlayWindows.append(window)
        }

        overlayWindows.first?.makeKey()

        // Intercept keyboard & mouse events so wiping the keyboard/trackpad doesn't trigger actions,
        // except Command + Esc (keyCode 53 with .command) which exits immediately.
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            guard let self = self, self.isActive else { return event }

            if event.type == .keyDown {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                // keyCode 53 is Escape on macOS; check if Command is held
                if event.keyCode == 53 && flags.contains(.command) {
                    Task { @MainActor in
                        self.stopCleaning(reason: "Screen Cleaner stopped via ⌘ + Esc.")
                    }
                    return nil
                }
                // Swallow all other keystrokes while cleaning the keyboard/screen
                return nil
            }

            if event.type == .keyUp {
                return nil
            }

            // Swallow clicks/scrolls so wiping the trackpad doesn't click anything
            if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown || event.type == .scrollWheel {
                return nil
            }

            return event
        }

        // Start 1-second countdown timer
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isActive else { return }
                if self.remainingSeconds > 1 {
                    self.remainingSeconds -= 1
                } else {
                    self.stopCleaning(reason: "2-minute Screen Cleaner timer finished.")
                }
            }
        }
    }

    func stopCleaning(reason: String? = nil) {
        guard isActive else { return }
        isActive = false

        countdownTimer?.invalidate()
        countdownTimer = nil

        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }

        for window in overlayWindows {
            window.orderOut(nil)
            window.close()
        }
        overlayWindows.removeAll()

        // Restore normal Dock and Menu Bar visibility
        NSApp.presentationOptions = []

        if let reason = reason {
            statusMessage = reason
        }
    }
}

struct ScreenCleanerOverlayView: View {
    @ObservedObject var manager: ScreenCleanerManager
    let isPrimaryDisplay: Bool

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if isPrimaryDisplay && manager.showMinimalHUD {
                VStack(spacing: 12) {
                    Spacer()

                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles.tv")
                                .font(.system(size: 16, weight: .medium))
                            Text("Screen Cleaner Active • \(manager.formattedRemainingTime)")
                                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        }

                        Text("Press  ⌘ + Esc  to exit anytime  •  Keyboard & Trackpad touches locked")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color.white.opacity(0.22))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.bottom, 48)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
