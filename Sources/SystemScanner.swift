import Foundation
import AppKit
import UserNotifications

@MainActor
final class SystemScanner: ObservableObject {
    @Published var report: ScanReport?
    @Published var isScanning: Bool = false
    @Published var scanProgressText: String = "Ready"
    @Published var statusBannerMessage: String?
    @Published var schedule: ScheduleConfig = ScheduleConfig()

    private let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
    private var appSupportDir: String {
        "\(homeDir)/Library/Application Support/MacCare"
    }
    private var lastReportPath: String {
        "\(appSupportDir)/last_report.json"
    }
    private var scheduleConfigPath: String {
        "\(appSupportDir)/schedule.json"
    }
    var launchAgentPath: String {
        "\(homeDir)/Library/LaunchAgents/com.chip.maccare.weekly.plist"
    }

    init() {
        loadSavedState()
    }

    func loadSavedState() {
        let fm = FileManager.default
        if let data = fm.contents(atPath: lastReportPath),
           let decoded = try? JSONDecoder().decode(ScanReport.self, from: data) {
            self.report = decoded
        }
        if let data = fm.contents(atPath: scheduleConfigPath),
           let decoded = try? JSONDecoder().decode(ScheduleConfig.self, from: data) {
            self.schedule = decoded
        } else {
            self.schedule.isEnabled = fm.fileExists(atPath: launchAgentPath)
        }
    }

    func saveReport(_ report: ScanReport) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: appSupportDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(report) {
            try? data.write(to: URL(fileURLWithPath: lastReportPath))
        }
    }

    func runFullScan() async {
        guard !isScanning else { return }
        isScanning = true
        statusBannerMessage = nil
        scanProgressText = "Checking hardware, battery, AI clutter, caches, and startup items..."

        let home = homeDir
        let newReport = await Task.detached(priority: .userInitiated) { () -> ScanReport in
            let metrics = Self.collectSystemMetrics()
            let recommendations = Self.collectRecommendations(homeDir: home)
            let security = Self.collectSecurityAudit(homeDir: home)
            return ScanReport(
                timestamp: Date(),
                metrics: metrics,
                recommendations: recommendations,
                security: security
            )
        }.value

        self.report = newReport
        saveReport(newReport)
        isScanning = false
        scanProgressText = "Last scan completed at \( newReport.timestamp.formatted(date: .abbreviated, time: .shortened) )"
    }

    // MARK: - Background CLI Mode (Weekly Scheduled Run)

    static func runBackgroundScanAndNotify() async {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        sendNotification(
            title: "MacCare Weekly Check Started",
            body: "Scanning your MacBook Air's storage, AI clutter, caches, battery, and security..."
        )

        let metrics = collectSystemMetrics()
        let recommendations = collectRecommendations(homeDir: home)
        let security = collectSecurityAudit(homeDir: home)
        let report = ScanReport(
            timestamp: Date(),
            metrics: metrics,
            recommendations: recommendations,
            security: security
        )

        let appSupport = "\(home)/Library/Application Support/MacCare"
        try? FileManager.default.createDirectory(atPath: appSupport, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(report) {
            try? data.write(to: URL(fileURLWithPath: "\(appSupport)/last_report.json"))
        }

        let cleanableStr = ByteCountFormatter.string(fromByteCount: report.totalCleanableBytes, countStyle: .file)
        let freeStr = ByteCountFormatter.string(fromByteCount: metrics.diskFreeBytes, countStyle: .file)
        let secStatus = security.allSecure ? "Security OK" : "Review Startup Items"

        sendNotification(
            title: "MacCare Weekly Check Complete",
            body: "Free space: \(freeStr) • Safe to clean: \(cleanableStr) • \(secStatus). Open MacCare to review."
        )
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }

    nonisolated static func sendNotification(title: String, body: String) {
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\" sound name \"Glass\""
        _ = runShell("/usr/bin/osascript", args: ["-e", script])
    }

    // MARK: - Actions on Recommendations

    func toggleSelection(for id: String) {
        guard var current = report,
              let idx = current.recommendations.firstIndex(where: { $0.id == id }) else { return }
        current.recommendations[idx].isSelected.toggle()
        report = current
    }

    func revealInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let parent = url.deletingLastPathComponent()
            NSWorkspace.shared.open(parent)
        }
    }

    func performAction(for item: CleanupRecommendation) async {
        await performActions(for: [item])
    }

    func performSelectedActions() async {
        guard let current = report else { return }
        let selected = current.recommendations.filter { $0.isSelected && $0.actionType != .revealOnly }
        guard !selected.isEmpty else { return }
        await performActions(for: selected)
    }

    private func performActions(for items: [CleanupRecommendation]) async {
        isScanning = true
        var freedBytes: Int64 = 0
        var cleanedNames: [String] = []

        for item in items {
            scanProgressText = "Cleaning \(item.title)..."
            let success = await Task.detached(priority: .userInitiated) { () -> Bool in
                let fm = FileManager.default
                switch item.actionType {
                case .trashItem:
                    guard fm.fileExists(atPath: item.path) else { return false }
                    do {
                        try fm.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                        return true
                    } catch {
                        return false
                    }
                case .trashContents:
                    guard let children = try? fm.contentsOfDirectory(atPath: item.path) else { return false }
                    var movedAny = false
                    for child in children {
                        let full = "\(item.path)/\(child)"
                        if (try? fm.trashItem(at: URL(fileURLWithPath: full), resultingItemURL: nil)) != nil {
                            movedAny = true
                        }
                    }
                    return movedAny
                case .brewCleanup:
                    if fm.fileExists(atPath: "/opt/homebrew/bin/brew") {
                        _ = Self.runShell("/opt/homebrew/bin/brew", args: ["cleanup", "--prune=all"])
                    }
                    if fm.fileExists(atPath: item.path),
                       let children = try? fm.contentsOfDirectory(atPath: item.path) {
                        for child in children {
                            let full = "\(item.path)/\(child)"
                            _ = try? fm.trashItem(at: URL(fileURLWithPath: full), resultingItemURL: nil)
                        }
                    }
                    return true
                case .emptyTrash:
                    guard let children = try? fm.contentsOfDirectory(atPath: item.path) else { return false }
                    var removedAny = false
                    for child in children {
                        let full = "\(item.path)/\(child)"
                        if (try? fm.removeItem(atPath: full)) != nil {
                            removedAny = true
                        }
                    }
                    return removedAny
                case .revealOnly:
                    return false
                }
            }.value

            if success {
                freedBytes += item.sizeBytes
                cleanedNames.append(item.title)
            }
        }

        isScanning = false
        await runFullScan()

        if !cleanedNames.isEmpty {
            let formatted = ByteCountFormatter.string(fromByteCount: freedBytes, countStyle: .file)
            statusBannerMessage = "Processed \(cleanedNames.joined(separator: ", ")) (\(formatted)). (Items moved to Trash can be restored anytime before emptying Trash.)"
        } else {
            statusBannerMessage = "No items were moved. Check permissions or inspect in Finder."
        }
    }

    // MARK: - Startup & Login Item Removal

    func removeStartupItem(_ item: StartupItem) async {
        let home = homeDir
        let msg = await Task.detached(priority: .userInitiated) { () -> String in
            let fm = FileManager.default
            let uid = getuid()

            switch item.kind {
            case .loginItem:
                let escapedName = item.name.replacingOccurrences(of: "\"", with: "\\\"")
                let script = "tell application \"System Events\" to delete login item \"\(escapedName)\""
                _ = Self.runShell("/usr/bin/osascript", args: ["-e", script])
                return "Removed Login Item '\(item.name)' from macOS Login Items."
            case .userAgent:
                _ = Self.runShell("/bin/launchctl", args: ["bootout", "gui/\(uid)", item.path])
                _ = Self.runShell("/bin/launchctl", args: ["unload", item.path])
                if fm.fileExists(atPath: item.path) {
                    _ = try? fm.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                }
                return "Unloaded and moved User LaunchAgent '\(item.name)' to your Trash."
            case .systemAgent, .systemDaemon:
                let escapedPath = item.path.replacingOccurrences(of: "'", with: "'\\''")
                let trashDest = "\(home)/.Trash/\(item.name)-\(Int(Date().timeIntervalSince1970))".replacingOccurrences(of: "'", with: "'\\''")
                let cmd = "/bin/launchctl bootout system '\(escapedPath)' 2>/dev/null || /bin/launchctl unload '\(escapedPath)' 2>/dev/null || true ; /bin/mv -f '\(escapedPath)' '\(trashDest)' && /usr/sbin/chown \(uid):staff '\(trashDest)'"
                let appleScriptCmd = cmd
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let osa = "do shell script \"\(appleScriptCmd)\" with administrator privileges"
                let out = Self.runShell("/usr/bin/osascript", args: ["-e", osa])
                if out.lowercased().contains("user canceled") {
                    return "Canceled removing '\(item.name)'."
                }
                return "Unloaded and moved System Startup Item '\(item.name)' to your Trash."
            }
        }.value

        await runFullScan()
        statusBannerMessage = msg
    }

    // MARK: - Weekly Schedule (LaunchAgent)

    func updateSchedule(_ newSchedule: ScheduleConfig) {
        self.schedule = newSchedule
        let fm = FileManager.default
        try? fm.createDirectory(atPath: appSupportDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(newSchedule) {
            try? data.write(to: URL(fileURLWithPath: scheduleConfigPath))
        }

        let uid = getuid()
        if newSchedule.isEnabled {
            let executablePath = "/Applications/MacCare.app/Contents/MacOS/MacCare"
            let plist: [String: Any] = [
                "Label": "com.chip.maccare.weekly",
                "ProgramArguments": [executablePath, "--background-scan"],
                "StartCalendarInterval": [
                    "Weekday": newSchedule.weekday,
                    "Hour": newSchedule.hour,
                    "Minute": newSchedule.minute
                ],
                "StandardOutPath": "\(appSupportDir)/weekly_scan.log",
                "StandardErrorPath": "\(appSupportDir)/weekly_scan.log",
                "RunAtLoad": false
            ]
            let launchAgentsDir = "\(homeDir)/Library/LaunchAgents"
            try? fm.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)
            if let plistData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? plistData.write(to: URL(fileURLWithPath: launchAgentPath))
            }
            _ = Self.runShell("/bin/launchctl", args: ["bootout", "gui/\(uid)", launchAgentPath])
            _ = Self.runShell("/bin/launchctl", args: ["bootstrap", "gui/\(uid)", launchAgentPath])
            let dayName = ScheduleConfig.weekdays.first(where: { $0.0 == newSchedule.weekday })?.1 ?? "Sunday"
            statusBannerMessage = String(format: "Weekly background scan scheduled for %@s at %02d:%02d.", dayName, newSchedule.hour, newSchedule.minute)
        } else {
            _ = Self.runShell("/bin/launchctl", args: ["bootout", "gui/\(uid)", launchAgentPath])
            try? fm.removeItem(atPath: launchAgentPath)
            statusBannerMessage = "Weekly background schedule turned off."
        }
    }

    func testNotificationNow() {
        Task {
            await Self.runBackgroundScanAndNotify()
            loadSavedState()
            statusBannerMessage = "Sent start & completion notifications and refreshed the report!"
        }
    }

    // MARK: - Collectors

    nonisolated static func collectSystemMetrics() -> SystemMetrics {
        var m = SystemMetrics()

        let cpuBrand = runShell("/usr/sbin/sysctl", args: ["-n", "machdep.cpu.brand_string"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !cpuBrand.isEmpty {
            m.macModel = "\(cpuBrand) MacBook Air"
        }

        let swVers = runShell("/usr/bin/sw_vers", args: ["-productVersion"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let buildVers = runShell("/usr/bin/sw_vers", args: ["-buildVersion"]).trimmingCharacters(in: .whitespacesAndNewlines)
        m.osVersion = "macOS \(swVers) (\(buildVers))"

        let uptimeRaw = runShell("/usr/bin/uptime", args: []).trimmingCharacters(in: .whitespacesAndNewlines)
        if let loadRange = uptimeRaw.range(of: "load averages:") {
            m.loadAverage = String(uptimeRaw[loadRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        if let upRange = uptimeRaw.range(of: "up "),
           let usersRange = uptimeRaw.range(of: " user") {
            let sub = uptimeRaw[upRange.upperBound..<usersRange.lowerBound]
            if let lastComma = sub.lastIndex(of: ",") {
                m.uptime = String(sub[..<lastComma]).trimmingCharacters(in: .whitespaces)
            }
        }

        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/System/Volumes/Data") {
            m.diskTotalBytes = (attrs[.systemSize] as? NSNumber)?.int64Value ?? 0
            m.diskFreeBytes = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        }

        // Battery
        let powerOut = runShell("/usr/sbin/system_profiler", args: ["SPPowerDataType"])
        for line in powerOut.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("State of Charge (%):") {
                m.batteryChargePercent = Int(trimmed.replacingOccurrences(of: "State of Charge (%):", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
            } else if trimmed.hasPrefix("Maximum Capacity:") {
                m.batteryMaxCapacity = trimmed.replacingOccurrences(of: "Maximum Capacity:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Cycle Count:") {
                m.batteryCycleCount = Int(trimmed.replacingOccurrences(of: "Cycle Count:", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
            } else if trimmed.hasPrefix("Condition:") {
                m.batteryCondition = trimmed.replacingOccurrences(of: "Condition:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Charging:") && m.isCharging == false {
                let val = trimmed.replacingOccurrences(of: "Charging:", with: "").trimmingCharacters(in: .whitespaces)
                if val.lowercased() == "yes" { m.isCharging = true }
            }
        }

        // Memory
        let memBytesStr = runShell("/usr/sbin/sysctl", args: ["-n", "hw.memsize"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let memBytes = Int64(memBytesStr) {
            m.memoryTotalGB = Int(memBytes / (1024 * 1024 * 1024))
        }
        let vmOut = runShell("/usr/bin/vm_stat", args: [])
        var activePages: Double = 0
        var wiredPages: Double = 0
        var compressedPages: Double = 0
        for line in vmOut.components(separatedBy: .newlines) {
            if line.contains("Pages active:") {
                activePages = parseVmStatNumber(line)
            } else if line.contains("Pages wired down:") {
                wiredPages = parseVmStatNumber(line)
            } else if line.contains("Pages occupied by compressor:") {
                compressedPages = parseVmStatNumber(line)
            }
        }
        let pageSizeGB = 16384.0 / (1024.0 * 1024.0 * 1024.0)
        m.memoryActiveGB = (activePages + wiredPages) * pageSizeGB
        m.memoryCompressedGB = compressedPages * pageSizeGB

        // Top CPU processes
        let psOut = runShell("/bin/ps", args: ["-Aceo", "pcpu,pmem,comm", "-r"])
        let lines = psOut.components(separatedBy: .newlines).dropFirst()
        var procs: [ProcessSummary] = []
        for line in lines.prefix(6) {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            if parts.count == 3 {
                procs.append(ProcessSummary(
                    name: String(parts[2]),
                    cpuPercent: "\(parts[0])%",
                    memPercent: "\(parts[1])%"
                ))
            }
        }
        m.topCPUProcesses = procs

        return m
    }

    nonisolated private static func parseVmStatNumber(_ line: String) -> Double {
        let digits = line.filter { $0.isNumber }
        return Double(digits) ?? 0
    }

    nonisolated static func collectRecommendations(homeDir: String) -> [CleanupRecommendation] {
        var list: [CleanupRecommendation] = []

        let candidates: [(id: String, title: String, subtitle: String, explanation: String, path: String, category: RecommendationCategory, safety: SafetyLevel, action: CleanupRecommendation.ActionType, defaultSelected: Bool)] = [
            // 1. AI Clutter & Intelligence Caches
            (
                id: "ai-apple-intelligenceflow",
                title: "Apple Intelligence Flow Cache",
                subtitle: "On-device Apple Intelligence workflow cache",
                explanation: "Safe to clear; macOS rebuilds temporary intelligence caches automatically as needed.",
                path: "\(homeDir)/Library/Caches/com.apple.intelligenceflow.intelligenceflowd",
                category: .aiClutter,
                safety: .safe,
                action: .trashContents,
                defaultSelected: true
            ),
            (
                id: "ai-apple-visualintelligence",
                title: "Apple Visual Intelligence & E5 Bundle Cache",
                subtitle: "Compiled CoreML / Neural Engine model caches",
                explanation: "Safe to clear; macOS recompiles neural engine bundles on demand.",
                path: "\(homeDir)/Library/Caches/com.apple.VisualIntelligenceCore",
                category: .aiClutter,
                safety: .safe,
                action: .trashContents,
                defaultSelected: true
            ),
            (
                id: "ai-apple-e5rt",
                title: "Apple Neural Engine E5RT Bundle Cache",
                subtitle: "~/Library/Caches/com.apple.e5rt.e5bundlecache",
                explanation: "Temporary compiled ML model graph cache. Safe to purge.",
                path: "\(homeDir)/Library/Caches/com.apple.e5rt.e5bundlecache",
                category: .aiClutter,
                safety: .safe,
                action: .trashContents,
                defaultSelected: true
            ),
            (
                id: "ai-gemini-cache",
                title: "Google Gemini macOS App Cache",
                subtitle: "~/Library/Caches/com.google.GeminiMacOS",
                explanation: "Temporary cache files for the Gemini macOS app. Safe to clear.",
                path: "\(homeDir)/Library/Caches/com.google.GeminiMacOS",
                category: .aiClutter,
                safety: .safe,
                action: .trashContents,
                defaultSelected: true
            ),
            (
                id: "ai-codex-support",
                title: "Codex AI Application Support Store",
                subtitle: "~/Library/Application Support/Codex",
                explanation: "Local data and caches stored by Codex (172 MB). Review before removing if you actively use Codex.",
                path: "\(homeDir)/Library/Application Support/Codex",
                category: .aiClutter,
                safety: .review,
                action: .trashContents,
                defaultSelected: false
            ),
            (
                id: "ai-ollama-models",
                title: "Ollama Local LLM Model Store",
                subtitle: "~/.ollama/models",
                explanation: "Downloaded local LLM weights for Ollama.",
                path: "\(homeDir)/.ollama",
                category: .aiClutter,
                safety: .review,
                action: .trashContents,
                defaultSelected: false
            ),
            (
                id: "ai-huggingface-cache",
                title: "HuggingFace Downloaded Models Cache",
                subtitle: "~/.cache/huggingface",
                explanation: "Cached AI weights and datasets downloaded from HuggingFace Hub.",
                path: "\(homeDir)/.cache/huggingface",
                category: .aiClutter,
                safety: .review,
                action: .trashContents,
                defaultSelected: false
            ),

            // 2. Developer & Xcode Caches
            (
                id: "xcode-device-support",
                title: "Xcode iOS DeviceSupport Symbols",
                subtitle: "Debug symbols downloaded when connecting iPhones/iPads to Xcode",
                explanation: "Safe to clean anytime you aren't actively debugging an iOS app in Xcode. If needed later, Xcode re-downloads symbols automatically.",
                path: "\(homeDir)/Library/Developer/Xcode/iOS DeviceSupport",
                category: .developer,
                safety: .safe,
                action: .trashContents,
                defaultSelected: true
            ),
            (
                id: "xcode-coresimulator",
                title: "Xcode CoreSimulator Caches & Devices",
                subtitle: "iOS Simulator runtime caches and virtual device data",
                explanation: "Safe to clean if you aren't actively testing inside the iOS Simulator.",
                path: "\(homeDir)/Library/Developer/CoreSimulator",
                category: .developer,
                safety: .safe,
                action: .trashContents,
                defaultSelected: true
            ),
            (
                id: "xcode-deriveddata",
                title: "Xcode DerivedData Build Cache",
                subtitle: "Intermediate build artifacts and indexes for Xcode projects",
                explanation: "100% safe to clean; Xcode rebuilds DerivedData cleanly the next time you compile a project.",
                path: "\(homeDir)/Library/Developer/Xcode/DerivedData",
                category: .developer,
                safety: .safe,
                action: .trashContents,
                defaultSelected: true
            ),

            // 3. System Junk, App Caches & Logs
            (
                id: "homebrew-cache",
                title: "Homebrew Package Download Cache",
                subtitle: "Cached installers (.tar.gz / .bottle) from past brew installs",
                explanation: "Runs 'brew cleanup --prune=all' and removes old package download archives. Installed packages are unaffected.",
                path: "\(homeDir)/Library/Caches/Homebrew",
                category: .cachesAndLogs,
                safety: .safe,
                action: .brewCleanup,
                defaultSelected: true
            ),
            (
                id: "google-cache",
                title: "Google & Chrome Local Cache",
                subtitle: "Browser and updater cache files in ~/Library/Caches/Google",
                explanation: "Clears temporary cached web/updater files without touching your bookmarks, passwords, or history.",
                path: "\(homeDir)/Library/Caches/Google",
                category: .cachesAndLogs,
                safety: .safe,
                action: .trashContents,
                defaultSelected: true
            ),
            (
                id: "geoservices-cache",
                title: "Apple Maps & GeoServices Cache",
                subtitle: "~/Library/Caches/GeoServices",
                explanation: "Temporary map tile and location lookup cache. Safe to clean.",
                path: "\(homeDir)/Library/Caches/GeoServices",
                category: .cachesAndLogs,
                safety: .safe,
                action: .trashContents,
                defaultSelected: true
            ),
            (
                id: "user-logs",
                title: "User Application & Crash Logs",
                subtitle: "Old diagnostic and crash log files in ~/Library/Logs",
                explanation: "Safe to remove old log files once your system is running normally.",
                path: "\(homeDir)/Library/Logs",
                category: .cachesAndLogs,
                safety: .safe,
                action: .trashContents,
                defaultSelected: true
            ),
            (
                id: "saved-app-state",
                title: "Saved Application Window States",
                subtitle: "~/Library/Saved Application State",
                explanation: "Stores temporary window positions from closed apps. Safe to clean to fix stuck app windows or reclaim space.",
                path: "\(homeDir)/Library/Saved Application State",
                category: .cachesAndLogs,
                safety: .safe,
                action: .trashContents,
                defaultSelected: false
            ),

            // 4. Mail & Messages Attachments
            (
                id: "mail-downloads",
                title: "Apple Mail Downloaded Attachments Cache",
                subtitle: "~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
                explanation: "Local copies of email attachments you opened in Mail. Original attachments remain on your mail server.",
                path: "\(homeDir)/Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
                category: .mailAndMessages,
                safety: .safe,
                action: .trashContents,
                defaultSelected: false
            ),
            (
                id: "mail-storage",
                title: "Apple Mail Local Mailbox Store",
                subtitle: "~/Library/Mail",
                explanation: "Local cached emails and attachments (1.2 GB). Click Reveal in Finder to inspect before removing anything.",
                path: "\(homeDir)/Library/Mail",
                category: .mailAndMessages,
                safety: .caution,
                action: .revealOnly,
                defaultSelected: false
            ),
            (
                id: "messages-attachments",
                title: "Messages (iMessage) Local Attachments",
                subtitle: "~/Library/Messages/Attachments",
                explanation: "Photos, videos, and files sent or received in Messages (988 MB). Reveal in Finder to review or clean old media.",
                path: "\(homeDir)/Library/Messages/Attachments",
                category: .mailAndMessages,
                safety: .review,
                action: .revealOnly,
                defaultSelected: false
            ),

            // 5. Trash Bins
            (
                id: "user-trash",
                title: "macOS User Trash Bin (~/.Trash)",
                subtitle: "Files currently sitting in your Trash waiting to be permanently emptied",
                explanation: "Emptying the Trash permanently removes items currently in ~/.Trash.",
                path: "\(homeDir)/.Trash",
                category: .trashBins,
                safety: .review,
                action: .emptyTrash,
                defaultSelected: false
            ),

            // 6. App Storage & Containers
            (
                id: "overcast-podcasts",
                title: "Overcast Downloaded Podcast Episodes",
                subtitle: "Offline audio files stored by Overcast (fm.overcast.overcast)",
                explanation: "Overcast is storing downloaded podcast episodes in its container. Review in Overcast settings or clean if you no longer need offline episodes.",
                path: "\(homeDir)/Library/Containers/EFD5119B-2596-4689-9BD1-F8A890CD639F",
                category: .appStorage,
                safety: .review,
                action: .revealOnly,
                defaultSelected: false
            ),
            (
                id: "cleanmymac-app",
                title: "CleanMyMac 5 Application",
                subtitle: "/Applications/CleanMyMac_5.app",
                explanation: "Use the 'App Uninstaller' tab to cleanly remove CleanMyMac 5 along with all of its background daemons and helpers.",
                path: "/Applications/CleanMyMac_5.app",
                category: .appStorage,
                safety: .review,
                action: .trashItem,
                defaultSelected: false
            ),

            // 7. Downloads & Device Backups
            (
                id: "ios-backups",
                title: "Local iPhone / iPad USB Backups",
                subtitle: "MobileSync backups stored locally on this Mac",
                explanation: "Local Finder USB backups of iPhones or iPads. Keep this unless you back up exclusively to iCloud or want to remove old device backups via Finder.",
                path: "\(homeDir)/Library/Application Support/MobileSync/Backup",
                category: .downloadsAndBackups,
                safety: .caution,
                action: .revealOnly,
                defaultSelected: false
            ),
            (
                id: "downloads-folder",
                title: "Downloads Folder Review",
                subtitle: "Downloaded archives, installers, media, and documents in ~/Downloads",
                explanation: "Click 'Reveal in Finder' or use the 'Large & Duplicate Files' tab to review and clean up large downloads.",
                path: "\(homeDir)/Downloads",
                category: .downloadsAndBackups,
                safety: .review,
                action: .revealOnly,
                defaultSelected: false
            )
        ]

        for c in candidates {
            let bytes = directorySizeBytes(c.path)
            // Show Trash even if small (> 100 KB), and other items if > 250 KB
            let minBytes: Int64 = (c.category == .trashBins || c.id == "mail-downloads") ? 100_000 : 500_000
            if bytes >= minBytes {
                list.append(CleanupRecommendation(
                    id: c.id,
                    title: c.title,
                    subtitle: c.subtitle,
                    explanation: c.explanation,
                    path: c.path,
                    sizeBytes: bytes,
                    category: c.category,
                    safety: c.safety,
                    actionType: c.action,
                    isSelected: c.defaultSelected
                ))
            }
        }

        return list.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    nonisolated static func directorySizeBytes(_ path: String) -> Int64 {
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        let out = runShell("/usr/bin/du", args: ["-sk", path])
        guard let firstLine = out.components(separatedBy: .newlines).first,
              let kbStr = firstLine.split(separator: "\t").first,
              let kb = Int64(kbStr.trimmingCharacters(in: .whitespaces)) else {
            return 0
        }
        return kb * 1024
    }

    nonisolated static func collectSecurityAudit(homeDir: String) -> SecurityAudit {
        var audit = SecurityAudit()

        let csrOut = runShell("/usr/bin/csrutil", args: ["status"])
        audit.sipEnabled = csrOut.lowercased().contains("enabled")

        let spctlOut = runShell("/usr/sbin/spctl", args: ["--status"])
        audit.gatekeeperEnabled = spctlOut.lowercased().contains("enabled")

        if let xpDict = NSDictionary(contentsOfFile: "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist"),
           let ver = xpDict["CFBundleShortVersionString"] as? String {
            audit.xprotectVersion = "v\(ver)"
        } else {
            audit.xprotectVersion = "Active"
        }

        if let xpRemDict = NSDictionary(contentsOfFile: "/Library/Apple/System/Library/CoreServices/XProtect.app/Contents/Info.plist"),
           let ver = xpRemDict["CFBundleShortVersionString"] as? String {
            audit.xprotectPayloadsVersion = "v\(ver)"
        } else {
            audit.xprotectPayloadsVersion = "Active"
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist"),
           let modDate = attrs[.modificationDate] as? Date {
            audit.xprotectLastUpdated = modDate.formatted(date: .abbreviated, time: .omitted)
        }

        var items: [StartupItem] = []

        // 1. Collect macOS Login Items via System Events
        let loginOut = runShell("/usr/bin/osascript", args: ["-e", "tell application \"System Events\" to get the name of every login item"])
        let loginNames = loginOut
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for loginName in loginNames {
            let appCandidate = "/Applications/\(loginName).app"
            let (trusted, vendor) = classifyLoginItem(loginName)
            items.append(StartupItem(
                name: loginName,
                scope: "macOS Login Item",
                kind: .loginItem,
                path: FileManager.default.fileExists(atPath: appCandidate) ? appCandidate : "/Applications",
                isKnownTrusted: trusted,
                vendor: vendor,
                modifiedDate: "Active at Login"
            ))
        }

        // 2. Collect LaunchAgents & LaunchDaemons
        let directories: [(String, String, StartupItemKind)] = [
            ("\(homeDir)/Library/LaunchAgents", "User LaunchAgent", .userAgent),
            ("/Library/LaunchAgents", "System LaunchAgent", .systemAgent),
            ("/Library/LaunchDaemons", "System LaunchDaemon", .systemDaemon)
        ]

        let fm = FileManager.default
        for (dirPath, scope, kind) in directories {
            guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
            for file in files where file.hasSuffix(".plist") {
                let fullPath = "\(dirPath)/\(file)"
                let (trusted, vendor) = classifyStartupItem(file)
                var dateStr = ""
                if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                   let mod = attrs[.modificationDate] as? Date {
                    dateStr = mod.formatted(date: .abbreviated, time: .omitted)
                }
                items.append(StartupItem(
                    name: file,
                    scope: scope,
                    kind: kind,
                    path: fullPath,
                    isKnownTrusted: trusted,
                    vendor: vendor,
                    modifiedDate: dateStr
                ))
            }
        }
        audit.startupItems = items
        return audit
    }

    nonisolated private static func classifyLoginItem(_ name: String) -> (Bool, String) {
        let lower = name.lowercased()
        if lower.contains("topnotch") { return (true, "TopNotch (Menu Bar Utility)") }
        if lower.contains("betterdisplay") { return (true, "BetterDisplay") }
        if lower.contains("gemini") { return (true, "Google Gemini Launcher") }
        if lower.contains("aldente") { return (true, "AppHouseKitchen (AlDente)") }
        if lower.contains("alfred") { return (true, "Running with Crayons (Alfred)") }
        if lower.contains("shottr") { return (true, "Shottr Screenshot Utility") }
        if lower.contains("istat") { return (true, "Bjango (iStat Menus)") }
        return (false, "User Login Item — Review")
    }

    nonisolated private static func classifyStartupItem(_ filename: String) -> (Bool, String) {
        let lower = filename.lowercased()
        if lower.hasPrefix("com.bjango.istatmenus") { return (true, "Bjango (iStat Menus)") }
        if lower.hasPrefix("com.apphousekitchen.aldente") { return (true, "AppHouseKitchen (AlDente Pro)") }
        if lower.hasPrefix("com.google.") { return (true, "Google LLC") }
        if lower.hasPrefix("com.adobe.") { return (true, "Adobe Inc.") }
        if lower.hasPrefix("com.docker.") { return (true, "Docker Inc.") }
        if lower.hasPrefix("net.tunnelblick.") { return (true, "Tunnelblick VPN") }
        if lower.hasPrefix("org.xquartz.") { return (true, "XQuartz Project") }
        if lower.hasPrefix("com.macpaw.cleanmymac") { return (true, "MacPaw (CleanMyMac 5)") }
        if lower.hasPrefix("com.chip.maccare") { return (true, "MacCare Weekly Schedule") }
        return (false, "Unrecognized / Review")
    }

    nonisolated static func runShell(_ executable: String, args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
