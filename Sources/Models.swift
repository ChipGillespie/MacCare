import Foundation

enum SafetyLevel: String, Codable {
    case safe = "Safe to Clean"
    case review = "Review First"
    case caution = "Keep Unless Needed"
}

enum RecommendationCategory: String, Codable, CaseIterable {
    case aiClutter = "AI Clutter & Intelligence Caches"
    case cachesAndLogs = "System Junk, App Caches & Logs"
    case developer = "Developer & Xcode Caches"
    case mailAndMessages = "Mail & Messages Attachments"
    case trashBins = "Trash Bins"
    case appStorage = "App Storage & Containers"
    case downloadsAndBackups = "Downloads & Device Backups"
}

struct CleanupRecommendation: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let explanation: String
    let path: String
    let sizeBytes: Int64
    let category: RecommendationCategory
    let safety: SafetyLevel
    let actionType: ActionType
    var isSelected: Bool

    enum ActionType: String, Codable {
        case trashContents // Moves contents of directory to Trash
        case trashItem     // Moves the item itself to Trash
        case brewCleanup   // Runs brew cleanup --prune=all and trashes cache
        case emptyTrash    // Empties ~/.Trash contents
        case revealOnly    // Opens in Finder for manual inspection
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

enum StartupItemKind: String, Codable {
    case loginItem = "macOS Login Item"
    case userAgent = "User LaunchAgent"
    case systemAgent = "System LaunchAgent"
    case systemDaemon = "System LaunchDaemon"
}

struct StartupItem: Identifiable, Codable, Hashable {
    var id: String { "\(kind.rawValue)-\(name)-\(path)" }
    let name: String
    let scope: String
    let kind: StartupItemKind
    let path: String
    let isKnownTrusted: Bool
    let vendor: String
    let modifiedDate: String
}

struct SecurityAudit: Codable {
    var sipEnabled: Bool = false
    var gatekeeperEnabled: Bool = false
    var xprotectVersion: String = "Checking..."
    var xprotectPayloadsVersion: String = "Checking..."
    var xprotectLastUpdated: String = "Unknown"
    var startupItems: [StartupItem] = []

    var allSecure: Bool {
        sipEnabled && gatekeeperEnabled && !startupItems.contains(where: { !$0.isKnownTrusted })
    }
}

struct SystemMetrics: Codable {
    var macModel: String = "Apple M2 MacBook Air"
    var osVersion: String = ""
    var uptime: String = ""
    var loadAverage: String = ""

    var diskTotalBytes: Int64 = 0
    var diskFreeBytes: Int64 = 0
    var diskUsedBytes: Int64 { max(0, diskTotalBytes - diskFreeBytes) }
    var diskUsedFraction: Double {
        guard diskTotalBytes > 0 else { return 0 }
        return Double(diskUsedBytes) / Double(diskTotalBytes)
    }

    var batteryChargePercent: Int = 0
    var batteryMaxCapacity: String = "N/A"
    var batteryCycleCount: Int = 0
    var batteryCondition: String = "Normal"
    var isCharging: Bool = false

    var memoryTotalGB: Int = 8
    var memoryActiveGB: Double = 0
    var memoryCompressedGB: Double = 0

    var topCPUProcesses: [ProcessSummary] = []
}

struct ProcessSummary: Identifiable, Codable, Hashable {
    var id: String { "\(name)-\(cpuPercent)-\(memPercent)" }
    let name: String
    let cpuPercent: String
    let memPercent: String
}

struct ScanReport: Codable {
    var timestamp: Date
    var metrics: SystemMetrics
    var recommendations: [CleanupRecommendation]
    var security: SecurityAudit

    var totalCleanableBytes: Int64 {
        recommendations.filter { $0.safety == .safe }.reduce(0) { $0 + $1.sizeBytes }
    }

    var totalReviewableBytes: Int64 {
        recommendations.reduce(0) { $0 + $1.sizeBytes }
    }
}

struct ScheduleConfig: Codable, Equatable {
    var isEnabled: Bool = false
    var weekday: Int = 1 // 1 = Sunday, 2 = Monday, ..., 7 = Saturday
    var hour: Int = 10
    var minute: Int = 0

    static let weekdays: [(Int, String)] = [
        (1, "Sunday"),
        (2, "Monday"),
        (3, "Tuesday"),
        (4, "Wednesday"),
        (5, "Thursday"),
        (6, "Friday"),
        (7, "Saturday")
    ]
}

// MARK: - App Uninstaller Models

enum AssociatedFileKind: String, Codable, CaseIterable {
    case appBundle = "Application Bundle"
    case launchDaemonOrAgent = "Background Agent / Daemon"
    case privilegedHelper = "Privileged Helper Tool"
    case applicationSupport = "Application Support"
    case container = "Sandbox / Group Container"
    case cache = "Caches"
    case preferences = "Preferences (.plist)"
    case savedStateAndLogs = "Saved State, Logs & HTTP Storage"
    case receipt = "Installer Receipt"
}

struct AssociatedAppFile: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let kind: AssociatedFileKind
    let sizeBytes: Int64
    let requiresAdmin: Bool
    var isSelected: Bool

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

struct InstalledAppInfo: Identifiable, Hashable {
    var id: String { appPath }
    let name: String
    let bundleId: String
    let version: String
    let appPath: String
    let appSizeBytes: Int64

    var formattedAppSize: String {
        ByteCountFormatter.string(fromByteCount: appSizeBytes, countStyle: .file)
    }
}

// MARK: - Large & Duplicate Files Models

struct LargeFileItem: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let sizeBytes: Int64
    let modifiedDate: Date
    var isSelected: Bool

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

struct DuplicateFileGroup: Identifiable, Hashable {
    let id: String // SHA256 hash
    let fileSizeBytes: Int64
    var files: [LargeFileItem]

    var wastedBytes: Int64 {
        guard files.count > 1 else { return 0 }
        return fileSizeBytes * Int64(files.count - 1)
    }

    var formattedEachSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    var formattedWastedSize: String {
        ByteCountFormatter.string(fromByteCount: wastedBytes, countStyle: .file)
    }
}

// MARK: - App Updater Models

enum UpdateSourceKind: String, Codable {
    case homebrewCask = "Homebrew GUI App (Cask)"
    case homebrewFormula = "Homebrew CLI Package"
    case sparkleFeed = "Direct App (Sparkle Feed)"
}

struct UpdatableAppItem: Identifiable, Hashable {
    var id: String { "\(source.rawValue)-\(identifier)" }
    let name: String
    let identifier: String
    let currentVersion: String
    let latestVersion: String
    let source: UpdateSourceKind
    let appPath: String?
    var isSelected: Bool
}

// MARK: - Malware Scanner Models (Apple XProtect + YARA)

enum MalwareScanMode: String, CaseIterable, Identifiable {
    case quick = "Quick Threat Scan (Downloads, Desktop, Startup & Active Processes)"
    case deep = "Deep System Scan (All User Folders + /Applications)"
    case custom = "Scan Custom File or Folder..."

    var id: String { rawValue }
}

enum ThreatSeverity: String, Codable {
    case critical = "Malware Signature Match"
    case suspicious = "Unsigned / Tampered Binary"
    case warning = "Suspicious Script / Persistence"
}

struct MalwareThreatFinding: Identifiable, Hashable {
    var id: String { "\(ruleName)-\(filePath)" }
    let ruleName: String
    let engine: String // "Apple XProtect YARA", "Community macOS YARA", "Apple Gatekeeper / Codesign"
    let severity: ThreatSeverity
    let filePath: String
    let description: String
    var isSelected: Bool
}

struct MalwareDefinitionStatus {
    var yaraInstalled: Bool = false
    var yaraVersion: String = "Not Installed"
    var xprotectYaraVersion: String = "Unknown"
    var xprotectYaraRuleCount: Int = 0
    var xprotectLastUpdated: String = "Unknown"
    var communityRulesCount: Int = 0
    var communityRulesLastUpdated: String = "Not Downloaded Yet"
}

