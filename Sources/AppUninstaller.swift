import Foundation
import AppKit

@MainActor
final class AppUninstaller: ObservableObject {
    @Published var installedApps: [InstalledAppInfo] = []
    @Published var selectedApp: InstalledAppInfo?
    @Published var associatedFiles: [AssociatedAppInfoGroup] = []
    @Published var flatAssociatedFiles: [AssociatedAppFile] = []
    @Published var isScanningApps: Bool = false
    @Published var isScanningDetails: Bool = false
    @Published var isUninstalling: Bool = false
    @Published var statusMessage: String?

    struct AssociatedAppInfoGroup: Identifiable {
        var id: String { kind.rawValue }
        let kind: AssociatedFileKind
        var files: [AssociatedAppFile]
    }

    private let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

    func loadInstalledApps() async {
        guard !isScanningApps else { return }
        isScanningApps = true
        let home = homeDir

        let apps = await Task.detached(priority: .userInitiated) { () -> [InstalledAppInfo] in
            let dirs = ["/Applications", "\(home)/Applications"]
            var discovered: [InstalledAppInfo] = []
            let fm = FileManager.default

            for dir in dirs {
                guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for item in items where item.hasSuffix(".app") {
                    let fullPath = "\(dir)/\(item)"
                    // Skip Apple system apps or MacCare itself by default
                    if item == "Safari.app" || item == "MacCare.app" { continue }
                    if let info = Self.readAppInfo(at: fullPath) {
                        discovered.append(info)
                    }
                }
            }
            return discovered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value

        self.installedApps = apps
        self.isScanningApps = false
    }

    func pickCustomApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Application to Inspect & Uninstall"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                let path = url.path
                if let info = await Task.detached(operation: { Self.readAppInfo(at: path) }).value {
                    if !installedApps.contains(where: { $0.appPath == info.appPath }) {
                        installedApps.insert(info, at: 0)
                    }
                    await selectAndScan(app: info)
                }
            }
        }
    }

    func selectAndScan(app: InstalledAppInfo) async {
        selectedApp = app
        isScanningDetails = true
        statusMessage = nil
        let home = homeDir

        let foundFiles = await Task.detached(priority: .userInitiated) { () -> [AssociatedAppFile] in
            Self.scanAssociatedFiles(for: app, homeDir: home)
        }.value

        self.flatAssociatedFiles = foundFiles
        rebuildGroups()
        isScanningDetails = false
    }

    func toggleFileSelection(path: String) {
        guard let idx = flatAssociatedFiles.firstIndex(where: { $0.path == path }) else { return }
        flatAssociatedFiles[idx].isSelected.toggle()
        rebuildGroups()
    }

    func selectAll(_ select: Bool) {
        for i in flatAssociatedFiles.indices {
            // Always keep the main .app bundle selected unless manually toggled
            flatAssociatedFiles[i].isSelected = select
        }
        rebuildGroups()
    }

    private func rebuildGroups() {
        var groups: [AssociatedAppInfoGroup] = []
        for kind in AssociatedFileKind.allCases {
            let matching = flatAssociatedFiles.filter { $0.kind == kind }
            if !matching.isEmpty {
                groups.append(AssociatedAppInfoGroup(kind: kind, files: matching))
            }
        }
        self.associatedFiles = groups
    }

    var totalSelectedBytes: Int64 {
        flatAssociatedFiles.filter { $0.isSelected }.reduce(0) { $0 + $1.sizeBytes }
    }

    var selectedRequiresAdmin: Bool {
        flatAssociatedFiles.contains { $0.isSelected && $0.requiresAdmin }
    }

    func revealInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    // MARK: - Perform Clean Uninstall

    func uninstallSelectedFiles() async {
        guard let app = selectedApp else { return }
        let selected = flatAssociatedFiles.filter { $0.isSelected }
        guard !selected.isEmpty else { return }

        isUninstalling = true
        statusMessage = "Stopping running processes and unloading background helpers for \(app.name)..."

        let home = homeDir
        let totalBytes = totalSelectedBytes
        let resultMsg = await Task.detached(priority: .userInitiated) { () -> String in
            let fm = FileManager.default
            let uid = getuid()

            // 1. Gracefully quit running app if active
            let runningApps = NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier == app.bundleId ||
                ($0.bundleURL?.path.hasPrefix(app.appPath) ?? false)
            }
            for rApp in runningApps {
                rApp.terminate()
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            for rApp in runningApps where !rApp.isTerminated {
                rApp.forceTerminate()
            }

            // 2. Unload user LaunchAgents selected for removal
            let userAgents = selected.filter { $0.kind == .launchDaemonOrAgent && !$0.requiresAdmin }
            for agent in userAgents {
                _ = SystemScanner.runShell("/bin/launchctl", args: ["bootout", "gui/\(uid)", agent.path])
                _ = SystemScanner.runShell("/bin/launchctl", args: ["unload", agent.path])
            }

            // 3. Separate user-writable vs admin-required files
            var userItems: [AssociatedAppFile] = []
            var adminItems: [AssociatedAppFile] = []

            for item in selected {
                if item.requiresAdmin {
                    adminItems.append(item)
                } else {
                    userItems.append(item)
                }
            }

            var movedCount = 0
            // Move user-writable items to Trash first, falling back to admin if needed
            for item in userItems {
                guard fm.fileExists(atPath: item.path) else { continue }
                if (try? fm.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)) != nil {
                    movedCount += 1
                } else {
                    adminItems.append(item)
                }
            }

            // 4. If any items require administrator privileges (e.g. /Library/LaunchDaemons, /Library/PrivilegedHelperTools, or root-owned .app)
            if !adminItems.isEmpty {
                var shellCommands: [String] = []
                let trashDir = "\(home)/.Trash"
                let timestamp = Int(Date().timeIntervalSince1970)

                for item in adminItems {
                    let escapedPath = item.path.replacingOccurrences(of: "'", with: "'\\''")
                    if item.kind == .launchDaemonOrAgent {
                        shellCommands.append("/bin/launchctl bootout system '\(escapedPath)' 2>/dev/null || /bin/launchctl unload '\(escapedPath)' 2>/dev/null || true")
                    }
                    let baseName = URL(fileURLWithPath: item.path).lastPathComponent
                    let destName = "\(baseName)-\(timestamp)"
                    let escapedDest = "\(trashDir)/\(destName)".replacingOccurrences(of: "'", with: "'\\''")
                    shellCommands.append("/bin/mv -f '\(escapedPath)' '\(escapedDest)' && /usr/sbin/chown -R \(uid):staff '\(escapedDest)'")
                }

                let combinedCmd = shellCommands.joined(separator: " ; ")
                let appleScriptCmd = combinedCmd
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let osa = "do shell script \"\(appleScriptCmd)\" with administrator privileges"
                let out = SystemScanner.runShell("/usr/bin/osascript", args: ["-e", osa])
                if !out.lowercased().contains("user canceled") {
                    movedCount += adminItems.count
                }
            }

            let formatted = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            return "Cleanly removed \(movedCount) items (\(formatted)) for \(app.name) and moved them to your Trash. (Rollback: Restore from Trash anytime before emptying.)"
        }.value

        isUninstalling = false
        statusMessage = resultMsg
        await loadInstalledApps()
        if let updated = installedApps.first(where: { $0.appPath == app.appPath }) {
            await selectAndScan(app: updated)
        } else {
            selectedApp = nil
            associatedFiles = []
            flatAssociatedFiles = []
        }
    }

    // MARK: - App Discovery & Deep File Scanner

    nonisolated static func readAppInfo(at appPath: String) -> InstalledAppInfo? {
        let plistPath = "\(appPath)/Contents/Info.plist"
        guard let dict = NSDictionary(contentsOfFile: plistPath) else { return nil }
        let bundleId = (dict["CFBundleIdentifier"] as? String) ?? ""
        guard !bundleId.isEmpty else { return nil }

        let fallbackName = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
        let displayName = (dict["CFBundleDisplayName"] as? String)
            ?? (dict["CFBundleName"] as? String)
            ?? fallbackName
        let version = (dict["CFBundleShortVersionString"] as? String)
            ?? (dict["CFBundleVersion"] as? String)
            ?? "1.0"
        let size = SystemScanner.directorySizeBytes(appPath)

        return InstalledAppInfo(
            name: displayName,
            bundleId: bundleId,
            version: version,
            appPath: appPath,
            appSizeBytes: size
        )
    }

    nonisolated static func scanAssociatedFiles(for app: InstalledAppInfo, homeDir: String) -> [AssociatedAppFile] {
        var results: [AssociatedAppFile] = []
        var seenPaths = Set<String>()
        let fm = FileManager.default

        func addFile(path: String, kind: AssociatedFileKind) {
            let standardized = URL(fileURLWithPath: path).standardized.path
            guard !seenPaths.contains(standardized), fm.fileExists(atPath: standardized) else { return }
            seenPaths.insert(standardized)

            let size = SystemScanner.directorySizeBytes(standardized)
            let parentDir = URL(fileURLWithPath: standardized).deletingLastPathComponent().path
            let needsAdmin = !fm.isWritableFile(atPath: standardized) || !fm.isWritableFile(atPath: parentDir) || standardized.hasPrefix("/Library/") || standardized.hasPrefix("/private/var/")

            results.append(AssociatedAppFile(
                path: standardized,
                kind: kind,
                sizeBytes: max(size, 4096),
                requiresAdmin: needsAdmin,
                isSelected: true
            ))
        }

        // 1. Always add the main .app bundle
        addFile(path: app.appPath, kind: .appBundle)

        // Build search tokens from bundleId and app name
        // Example: bundleId = "com.macpaw.CleanMyMac5", name = "CleanMyMac_5" or "CleanMyMac"
        let bundleLower = app.bundleId.lowercased()
        let bundleParts = bundleLower.split(separator: ".").map(String.init)
        let appFolderName = URL(fileURLWithPath: app.appPath).deletingPathExtension().lastPathComponent
        let cleanName = app.name.replacingOccurrences(of: " ", with: "").lowercased()
        let rawNameLower = app.name.lowercased()
        let folderNameLower = appFolderName.lowercased()

        // Vendor prefix (e.g., "com.macpaw." or "com.bjango.istatmenus")
        var bundlePrefix = bundleLower
        if bundleParts.count >= 3 {
            // e.g. com.macpaw.cleanmymac5 -> check both full bundleId and vendor+product prefix
            bundlePrefix = "\(bundleParts[0]).\(bundleParts[1]).\(bundleParts[2])"
        }

        // Specific known vendor prefixes when a single vendor bundle corresponds to the app
        var extraPrefixes: [String] = [bundleLower, bundlePrefix]
        if bundleLower.contains("cleanmymac") || bundleLower.contains("macpaw") {
            extraPrefixes.append("com.macpaw.cleanmymac")
        }

        func matchesApp(_ itemName: String) -> Bool {
            let lower = itemName.lowercased()
            for prefix in extraPrefixes where prefix.count >= 6 {
                if lower.contains(prefix) { return true }
            }
            if cleanName.count >= 4 && lower.contains(cleanName) { return true }
            if rawNameLower.count >= 4 && lower.contains(rawNameLower) { return true }
            if folderNameLower.count >= 4 && lower.contains(folderNameLower) { return true }
            return false
        }

        let searchLocations: [(String, AssociatedFileKind)] = [
            // Background Agents & Daemons
            ("\(homeDir)/Library/LaunchAgents", .launchDaemonOrAgent),
            ("/Library/LaunchAgents", .launchDaemonOrAgent),
            ("/Library/LaunchDaemons", .launchDaemonOrAgent),

            // Privileged Helpers
            ("/Library/PrivilegedHelperTools", .privilegedHelper),

            // Application Support
            ("\(homeDir)/Library/Application Support", .applicationSupport),
            ("/Library/Application Support", .applicationSupport),
            ("\(homeDir)/Library/Application Support/CrashReporter", .savedStateAndLogs),

            // Sandboxed Containers, Group Containers & Scripts
            ("\(homeDir)/Library/Containers", .container),
            ("\(homeDir)/Library/Group Containers", .container),
            ("\(homeDir)/Library/Application Scripts", .container),
            ("\(homeDir)/Library/Daemon Containers", .container),

            // Caches
            ("\(homeDir)/Library/Caches", .cache),
            ("/Library/Caches", .cache),

            // Preferences
            ("\(homeDir)/Library/Preferences", .preferences),
            ("\(homeDir)/Library/Preferences/ByHost", .preferences),
            ("/Library/Preferences", .preferences),

            // Saved State, Logs, HTTPStorages, WebKit, Cookies
            ("\(homeDir)/Library/Saved Application State", .savedStateAndLogs),
            ("\(homeDir)/Library/Logs", .savedStateAndLogs),
            ("/Library/Logs", .savedStateAndLogs),
            ("\(homeDir)/Library/HTTPStorages", .savedStateAndLogs),
            ("\(homeDir)/Library/WebKit", .savedStateAndLogs),
            ("\(homeDir)/Library/Cookies", .savedStateAndLogs),

            // Installer Receipts
            ("/private/var/db/receipts", .receipt)
        ]

        for (dirPath, kind) in searchLocations {
            guard let entries = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
            for entry in entries {
                let fullPath = "\(dirPath)/\(entry)"
                if matchesApp(entry) {
                    addFile(path: fullPath, kind: kind)
                } else if kind == .container && dirPath.hasSuffix("/Containers") {
                    // Check UUID-named containers via .com.apple.containermanagerd.metadata.plist
                    let metaPath = "\(fullPath)/.com.apple.containermanagerd.metadata.plist"
                    if let meta = NSDictionary(contentsOfFile: metaPath),
                       let idStr = meta["MCMMetadataIdentifier"] as? String,
                       matchesApp(idStr) {
                        addFile(path: fullPath, kind: kind)
                    }
                }
            }
        }

        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }
}
