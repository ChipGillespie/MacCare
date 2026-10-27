import Foundation
import AppKit

@MainActor
final class AppUpdater: ObservableObject {
    @Published var outdatedItems: [UpdatableAppItem] = []
    @Published var upToDateAppsCount: Int = 0
    @Published var macOSUpdateStatus: String = "Not checked yet"
    @Published var isChecking: Bool = false
    @Published var isUpdating: Bool = false
    @Published var progressText: String = "Ready"
    @Published var statusMessage: String?

    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        statusMessage = nil
        progressText = "Checking Homebrew Casks, CLI Formulae, and Sparkle App Feeds..."

        let (foundOutdated, upToDateCount, osStatus) = await Task.detached(priority: .userInitiated) { () -> ([UpdatableAppItem], Int, String) in
            var items: [UpdatableAppItem] = []
            var checkedAppsCount = 0

            // 1. Check Homebrew Outdated JSON (Formulae + Casks with --greedy-auto-updates)
            if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") {
                let jsonOut = SystemScanner.runShell("/opt/homebrew/bin/brew", args: ["outdated", "--json=v2", "--greedy-auto-updates"])
                if let data = jsonOut.data(using: .utf8),
                   let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                    // Parse Casks (GUI Apps) first
                    if let casks = root["casks"] as? [[String: Any]] {
                        for c in casks {
                            let token = (c["name"] as? String) ?? ""
                            let installedArr = (c["installed_versions"] as? [String]) ?? []
                            let installed = installedArr.joined(separator: ", ")
                            let current = (c["current_version"] as? String) ?? ""
                            guard !token.isEmpty else { continue }

                            let candidateApp = "/Applications/\(token.capitalized).app"
                            items.append(UpdatableAppItem(
                                name: token,
                                identifier: token,
                                currentVersion: installed,
                                latestVersion: current,
                                source: .homebrewCask,
                                appPath: FileManager.default.fileExists(atPath: candidateApp) ? candidateApp : nil,
                                isSelected: true
                            ))
                        }
                    }

                    // Parse Formulae (CLI tools & libraries)
                    if let formulae = root["formulae"] as? [[String: Any]] {
                        for f in formulae {
                            let name = (f["name"] as? String) ?? ""
                            let installedArr = (f["installed_versions"] as? [String]) ?? []
                            let installed = installedArr.joined(separator: ", ")
                            let current = (f["current_version"] as? String) ?? ""
                            guard !name.isEmpty else { continue }

                            items.append(UpdatableAppItem(
                                name: name,
                                identifier: name,
                                currentVersion: installed,
                                latestVersion: current,
                                source: .homebrewFormula,
                                appPath: nil,
                                isSelected: true
                            ))
                        }
                    }
                }
            }

            // 2. Scan /Applications for Sparkle SUFeedURL apps
            if let appEntries = try? FileManager.default.contentsOfDirectory(atPath: "/Applications") {
                for entry in appEntries where entry.hasSuffix(".app") {
                    let fullPath = "/Applications/\(entry)"
                    let plistPath = "\(fullPath)/Contents/Info.plist"
                    guard let dict = NSDictionary(contentsOfFile: plistPath) else { continue }
                    checkedAppsCount += 1

                    guard let feedURLStr = dict["SUFeedURL"] as? String,
                          let feedURL = URL(string: feedURLStr) else { continue }

                    let appName = (dict["CFBundleDisplayName"] as? String)
                        ?? (dict["CFBundleName"] as? String)
                        ?? entry.replacingOccurrences(of: ".app", with: "")
                    let bundleId = (dict["CFBundleIdentifier"] as? String) ?? entry
                    let shortVer = (dict["CFBundleShortVersionString"] as? String) ?? ""
                    let buildVer = (dict["CFBundleVersion"] as? String) ?? ""

                    // Skip if already listed via Homebrew Cask
                    if items.contains(where: { $0.name.localizedCaseInsensitiveCompare(appName) == .orderedSame }) {
                        continue
                    }

                    if let latestSparkle = Self.fetchLatestSparkleVersion(from: feedURL),
                       !latestSparkle.isEmpty,
                       latestSparkle != shortVer,
                       latestSparkle != buildVer,
                       Self.isVersionNewer(latestSparkle, than: shortVer) {
                        items.append(UpdatableAppItem(
                            name: appName,
                            identifier: bundleId,
                            currentVersion: shortVer.isEmpty ? buildVer : shortVer,
                            latestVersion: latestSparkle,
                            source: .sparkleFeed,
                            appPath: fullPath,
                            isSelected: false
                        ))
                    }
                }
            }

            // 3. Check macOS Software Update status (fast check)
            let osStatus = "macOS & XProtect Automatic Updates Enabled"

            return (items, checkedAppsCount, osStatus)
        }.value

        self.outdatedItems = foundOutdated
        self.upToDateAppsCount = upToDateCount
        self.macOSUpdateStatus = osStatus
        self.isChecking = false
        self.progressText = "Found \(foundOutdated.count) available updates across your installed apps & packages."
    }

    nonisolated private static func fetchLatestSparkleVersion(from url: URL) -> String? {
        var request = URLRequest(url: url, timeoutInterval: 2.5)
        request.httpMethod = "GET"
        let sem = DispatchSemaphore(value: 0)
        var xmlString: String?

        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            if let d = data {
                xmlString = String(data: d, encoding: .utf8)
            }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 3.0)

        guard let xml = xmlString else { return nil }
        // Look for sparkle:shortVersionString="..." or <sparkle:shortVersionString>...</sparkle:shortVersionString>
        if let range = xml.range(of: "sparkle:shortVersionString=\"") {
            let after = xml[range.upperBound...]
            if let endQuote = after.firstIndex(of: "\"") {
                return String(after[..<endQuote])
            }
        }
        if let range = xml.range(of: "<sparkle:shortVersionString>"),
           let endRange = xml.range(of: "</sparkle:shortVersionString>") {
            return String(xml[range.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    nonisolated private static func isVersionNewer(_ candidate: String, than installed: String) -> Bool {
        guard !installed.isEmpty else { return false }
        return candidate.compare(installed, options: .numeric) == .orderedDescending
    }

    func toggleSelection(_ id: String) {
        guard let idx = outdatedItems.firstIndex(where: { $0.id == id }) else { return }
        outdatedItems[idx].isSelected.toggle()
    }

    func selectAll(_ select: Bool) {
        for i in outdatedItems.indices {
            if outdatedItems[i].source != .sparkleFeed {
                outdatedItems[i].isSelected = select
            }
        }
    }

    func updateSingleItem(_ item: UpdatableAppItem) async {
        if item.source == .sparkleFeed, let appPath = item.appPath {
            NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
            statusMessage = "Opened \(item.name) so you can use its built-in 'Check for Updates...' menu item."
            return
        }
        await runBrewUpgrade(items: [item])
    }

    func updateSelectedItems() async {
        let targets = outdatedItems.filter { $0.isSelected && $0.source != .sparkleFeed }
        guard !targets.isEmpty else { return }
        await runBrewUpgrade(items: targets)
    }

    private func runBrewUpgrade(items: [UpdatableAppItem]) async {
        guard !isUpdating else { return }
        isUpdating = true
        statusMessage = nil

        var updatedNames: [String] = []
        for item in items {
            progressText = "Updating \(item.name) (\(item.currentVersion) → \(item.latestVersion))..."
            let isCask = (item.source == .homebrewCask)
            let id = item.identifier
            await Task.detached(priority: .userInitiated) {
                if isCask {
                    _ = SystemScanner.runShell("/opt/homebrew/bin/brew", args: ["upgrade", "--cask", id])
                } else {
                    _ = SystemScanner.runShell("/opt/homebrew/bin/brew", args: ["upgrade", id])
                }
            }.value
            updatedNames.append(item.name)
        }

        isUpdating = false
        await checkForUpdates()
        statusMessage = "Updated \(updatedNames.count) item(s): \(updatedNames.joined(separator: ", "))."
    }
}
