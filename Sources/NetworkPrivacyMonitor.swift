import Foundation
import AppKit
import Darwin

struct NetworkConnectionItem: Identifiable, Hashable {
    let id: String
    let processName: String
    let pid: Int32
    let user: String
    let proto: String
    let localEndpoint: String
    let remoteEndpoint: String
    let state: String
    let binaryPath: String?
    let isListening: Bool
    let isWildcardBind: Bool // true if listening on *:port or 0.0.0.0:port
}

enum PrivacyCapability: String, CaseIterable, Identifiable, Hashable {
    case camera = "Camera"
    case microphone = "Microphone"
    case screenCapture = "Screen Recording"
    case automation = "Automation / AppleEvents"
    case bluetooth = "Bluetooth"
    case location = "Location Services"
    case fullDiskOrAdmin = "System / Disk Access"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .camera: return "camera.fill"
        case .microphone: return "mic.fill"
        case .screenCapture: return "rectangle.inset.filled.and.person.filled"
        case .automation: return "gearshape.arrow.triangle.2.circlepath"
        case .bluetooth: return "antenna.radiowaves.left.and.right"
        case .location: return "location.fill"
        case .fullDiskOrAdmin: return "externaldrive.fill.badge.checkmark"
        }
    }

    var settingsURLString: String {
        switch self {
        case .camera: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        case .microphone: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .screenCapture: return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .automation: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        case .bluetooth: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
        case .location: return "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        case .fullDiskOrAdmin: return "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        }
    }
}

struct AppPrivacyEntry: Identifiable, Hashable {
    let id: String // bundleId + path
    let appName: String
    let bundleId: String
    let appPath: String
    let capabilities: [PrivacyCapability]
    let tccGrantedServices: [String]
}

@MainActor
final class NetworkPrivacyMonitor: ObservableObject {
    @Published var listeningPorts: [NetworkConnectionItem] = []
    @Published var establishedConnections: [NetworkConnectionItem] = []
    @Published var privacyEntries: [AppPrivacyEntry] = []
    @Published var firewallEnabled: Bool = false
    @Published var stealthModeEnabled: Bool = false
    @Published var activeSystemExtensionsCount: Int = 0
    @Published var isScanning: Bool = false
    @Published var statusMessage: String?
    @Published var lastUpdated: Date?

    func runAudit() async {
        guard !isScanning else { return }
        isScanning = true
        statusMessage = nil

        let (listeners, established, fwOn, stealthOn, sysExtCount, privApps) = await Task.detached(priority: .userInitiated) { () -> (
            [NetworkConnectionItem],
            [NetworkConnectionItem],
            Bool,
            Bool,
            Int,
            [AppPrivacyEntry]
        ) in
            let (listenList, estList) = Self.collectNetworkConnections()
            let (fw, stealth) = Self.checkFirewallState()
            let extCount = Self.countSystemExtensions()
            let apps = Self.auditAppPrivacyPermissions()
            return (listenList, estList, fw, stealth, extCount, apps)
        }.value

        self.listeningPorts = listeners
        self.establishedConnections = established
        self.firewallEnabled = fwOn
        self.stealthModeEnabled = stealthOn
        self.activeSystemExtensionsCount = sysExtCount
        self.privacyEntries = privApps
        self.lastUpdated = Date()
        self.isScanning = false
    }

    func openPrivacySettings(for capability: PrivacyCapability? = nil) {
        let urlStr = capability?.settingsURLString ?? "x-apple.systempreferences:com.apple.preference.security?Privacy"
        if let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
        }
    }

    func openFirewallSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Firewall") {
            NSWorkspace.shared.open(url)
        }
    }

    func revealInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    // MARK: - Network Connections via lsof -i -n -P

    nonisolated private static func collectNetworkConnections() -> ([NetworkConnectionItem], [NetworkConnectionItem]) {
        let output = runCommand("/usr/sbin/lsof", arguments: ["-i", "-n", "-P"])
        var listeners: [NetworkConnectionItem] = []
        var established: [NetworkConnectionItem] = []
        var seenKeys: Set<String> = []
        var pidPathCache: [Int32: String] = [:]

        let lines = output.components(separatedBy: .newlines)
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 9 else { continue }

            let rawProcName = parts[0].replacingOccurrences(of: "\\x20", with: " ")
            let pid = Int32(parts[1]) ?? 0
            let user = parts[2]
            let proto = parts[7] // TCP or UDP

            let nameAndState = parts[8...].joined(separator: " ")
            var state = "ACTIVE"
            var endpointPart = nameAndState

            if let parenStart = nameAndState.range(of: " ("),
               let parenEnd = nameAndState.range(of: ")", range: parenStart.upperBound..<nameAndState.endIndex) {
                state = String(nameAndState[parenStart.upperBound..<parenEnd.lowerBound])
                endpointPart = String(nameAndState[..<parenStart.lowerBound])
            } else if proto == "UDP" {
                state = "UDP"
            }

            let isListening = (state == "LISTEN" || (proto == "UDP" && !endpointPart.contains("->")))
            var localEP = endpointPart
            var remoteEP = "—"

            if let arrowRange = endpointPart.range(of: "->") {
                localEP = String(endpointPart[..<arrowRange.lowerBound])
                remoteEP = String(endpointPart[arrowRange.upperBound...])
            }

            let dedupKey = "\(pid)|\(proto)|\(localEP)|\(remoteEP)|\(state)"
            guard !seenKeys.contains(dedupKey) else { continue }
            seenKeys.insert(dedupKey)

            let binPath: String?
            if let cached = pidPathCache[pid] {
                binPath = cached.isEmpty ? nil : cached
            } else {
                let resolved = resolveBinaryPath(for: pid)
                pidPathCache[pid] = resolved ?? ""
                binPath = resolved
            }

            let isWildcard = isListening && (localEP.hasPrefix("*:") || localEP.hasPrefix("0.0.0.0:") || localEP.hasPrefix("[::]:"))

            let item = NetworkConnectionItem(
                id: dedupKey,
                processName: rawProcName,
                pid: pid,
                user: user,
                proto: proto,
                localEndpoint: localEP,
                remoteEndpoint: remoteEP,
                state: state,
                binaryPath: binPath,
                isListening: isListening,
                isWildcardBind: isWildcard
            )

            if isListening {
                if state == "LISTEN" {
                    listeners.append(item)
                }
            } else if state == "ESTABLISHED" || state == "SYN_SENT" || state == "CLOSE_WAIT" {
                established.append(item)
            }
        }

        listeners.sort {
            if $0.isWildcardBind != $1.isWildcardBind {
                return $0.isWildcardBind && !$1.isWildcardBind
            }
            return $0.processName.localizedCaseInsensitiveCompare($1.processName) == .orderedAscending
        }

        established.sort {
            $0.processName.localizedCaseInsensitiveCompare($1.processName) == .orderedAscending
        }

        return (listeners, established)
    }

    nonisolated private static func resolveBinaryPath(for pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let ret = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard ret > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Firewall & System Extensions Check

    nonisolated private static func checkFirewallState() -> (Bool, Bool) {
        let fwOut = runCommand("/usr/libexec/ApplicationFirewall/socketfilterfw", arguments: ["--getglobalstate"])
        let stealthOut = runCommand("/usr/libexec/ApplicationFirewall/socketfilterfw", arguments: ["--getstealthmode"])
        let fwEnabled = fwOut.localizedCaseInsensitiveContains("enabled")
        let stealthEnabled = stealthOut.localizedCaseInsensitiveContains("enabled")
        return (fwEnabled, stealthEnabled)
    }

    nonisolated private static func countSystemExtensions() -> Int {
        let out = runCommand("/usr/bin/systemextensionsctl", arguments: ["list"])
        let activeLines = out.components(separatedBy: .newlines).filter {
            $0.contains("[activated enabled]")
        }
        return activeLines.count
    }

    // MARK: - App Privacy Permissions Audit

    nonisolated private static func auditAppPrivacyPermissions() -> [AppPrivacyEntry] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let appDirs = ["/Applications", "\(home)/Applications"]

        // Query user TCC database if readable for explicit grants
        var tccGrantsByBundle: [String: [String]] = [:]
        let userTCCPath = "\(home)/Library/Application Support/com.apple.TCC/TCC.db"
        if fm.isReadableFile(atPath: userTCCPath) {
            let sql = "SELECT client, service FROM access WHERE auth_value = 2;"
            let out = runCommand("/usr/bin/sqlite3", arguments: [userTCCPath, sql])
            for line in out.components(separatedBy: .newlines) {
                let parts = line.split(separator: "|").map(String.init)
                if parts.count == 2 {
                    let client = parts[0]
                    let service = parts[1].replacingOccurrences(of: "kTCCService", with: "")
                    tccGrantsByBundle[client, default: []].append(service)
                }
            }
        }

        var results: [AppPrivacyEntry] = []

        for dir in appDirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let appPath = "\(dir)/\(item)"
                let plistPath = "\(appPath)/Contents/Info.plist"
                guard let dict = NSDictionary(contentsOfFile: plistPath) as? [String: Any] else { continue }

                let bundleId = (dict["CFBundleIdentifier"] as? String) ?? item
                let appName = (dict["CFBundleDisplayName"] as? String)
                    ?? (dict["CFBundleName"] as? String)
                    ?? item.replacingOccurrences(of: ".app", with: "")

                var caps: [PrivacyCapability] = []
                if dict["NSCameraUsageDescription"] != nil || dict["NSCameraReactionEffectGesturesEnabledDefault"] != nil {
                    caps.append(.camera)
                }
                if dict["NSMicrophoneUsageDescription"] != nil {
                    caps.append(.microphone)
                }
                if dict["NSScreenCaptureUsageDescription"] != nil {
                    caps.append(.screenCapture)
                }
                if dict["NSAppleEventsUsageDescription"] != nil {
                    caps.append(.automation)
                }
                if dict["NSBluetoothAlwaysUsageDescription"] != nil || dict["NSBluetoothPeripheralUsageDescription"] != nil {
                    caps.append(.bluetooth)
                }
                if dict["NSLocationUsageDescription"] != nil || dict["NSLocationWhenInUseUsageDescription"] != nil || dict["NSLocationAlwaysAndWhenInUseUsageDescription"] != nil {
                    caps.append(.location)
                }
                if dict["NSSystemAdministrationUsageDescription"] != nil || dict["NSDesktopFolderUsageDescription"] != nil || dict["NSDocumentsFolderUsageDescription"] != nil || dict["NSDownloadsFolderUsageDescription"] != nil {
                    caps.append(.fullDiskOrAdmin)
                }

                let tccServices = tccGrantsByBundle[bundleId] ?? []
                if tccServices.contains("ScreenCapture") && !caps.contains(.screenCapture) {
                    caps.append(.screenCapture)
                }
                if tccServices.contains("Camera") && !caps.contains(.camera) {
                    caps.append(.camera)
                }
                if tccServices.contains("Microphone") && !caps.contains(.microphone) {
                    caps.append(.microphone)
                }
                if (tccServices.contains("SystemPolicyAllFiles") || tccServices.contains("Accessibility")) && !caps.contains(.fullDiskOrAdmin) {
                    caps.append(.fullDiskOrAdmin)
                }

                if !caps.isEmpty || !tccServices.isEmpty {
                    results.append(AppPrivacyEntry(
                        id: "\(bundleId)|\(appPath)",
                        appName: appName,
                        bundleId: bundleId,
                        appPath: appPath,
                        capabilities: caps,
                        tccGrantedServices: Array(Set(tccServices)).sorted()
                    ))
                }
            }
        }

        results.sort {
            if $0.capabilities.count != $1.capabilities.count {
                return $0.capabilities.count > $1.capabilities.count
            }
            return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
        return results
    }

    nonisolated private static func runCommand(_ launchPath: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
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
