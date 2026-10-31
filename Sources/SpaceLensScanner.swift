import Foundation
import AppKit
import SwiftUI

struct SpaceLensNode: Identifiable, Hashable {
    let id: String // Full path
    let name: String
    let path: String
    let isDirectory: Bool
    let sizeBytes: Int64
    let modifiedDate: Date
    let childCount: Int
    let fractionOfParent: Double
    let colorIndex: Int

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var percentageString: String {
        String(format: "%.1f%%", fractionOfParent * 100.0)
    }
}

@MainActor
final class SpaceLensScanner: ObservableObject {
    @Published var currentRootPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var nodes: [SpaceLensNode] = []
    @Published var totalDirectoryBytes: Int64 = 0
    @Published var isScanning: Bool = false
    @Published var scanProgressText: String = "Ready to analyze directory space"
    @Published var statusMessage: String?
    @Published var navigationStack: [String] = []

    private var sizeCache: [String: Int64] = [:]
    private let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

    static let palette: [Color] = [
        .teal, .blue, .indigo, .purple, .pink, .orange, .yellow, .mint, .cyan, .green
    ]

    var breadcrumbs: [(name: String, path: String)] {
        var result: [(String, String)] = []
        let components = (currentRootPath as NSString).pathComponents
        var runningPath = ""
        for comp in components {
            if comp == "/" {
                runningPath = "/"
                result.append(("Macintosh HD", "/"))
            } else {
                if runningPath == "/" {
                    runningPath = "/\(comp)"
                } else {
                    runningPath = "\(runningPath)/\(comp)"
                }
                result.append((comp, runningPath))
            }
        }
        return result
    }

    func scanDirectory(at path: String, pushHistory: Bool = true) async {
        guard !isScanning else { return }
        if pushHistory && path != currentRootPath {
            navigationStack.append(currentRootPath)
        }
        currentRootPath = path
        isScanning = true
        statusMessage = nil
        scanProgressText = "Scanning \(URL(fileURLWithPath: path).lastPathComponent)..."

        let existingCache = sizeCache

        let (computedNodes, totalBytes, updatedCache) = await Task.detached(priority: .userInitiated) { () -> ([SpaceLensNode], Int64, [String: Int64]) in
            let fm = FileManager.default
            var localCache = existingCache
            guard let contents = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey],
                options: []
            ) else {
                return ([], 0, localCache)
            }

            struct RawEntry {
                let name: String
                let path: String
                let isDir: Bool
                let size: Int64
                let modDate: Date
                let childCount: Int
            }

            var rawEntries: [RawEntry] = []

            for itemURL in contents {
                let itemPath = itemURL.path
                let name = itemURL.lastPathComponent
                if name == ".DS_Store" { continue }

                let vals = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .isSymbolicLinkKey])
                if vals?.isSymbolicLink == true { continue }

                let isDir = (vals?.isDirectory == true)
                let modDate = vals?.contentModificationDate ?? Date.distantPast

                if isDir {
                    let childCount = (try? fm.contentsOfDirectory(atPath: itemPath).count) ?? 0
                    let dirSize: Int64
                    if let cached = localCache[itemPath] {
                        dirSize = cached
                    } else {
                        dirSize = Self.fastDirectorySize(at: itemURL)
                        localCache[itemPath] = dirSize
                    }
                    if dirSize > 0 {
                        rawEntries.append(RawEntry(
                            name: name,
                            path: itemPath,
                            isDir: true,
                            size: dirSize,
                            modDate: modDate,
                            childCount: childCount
                        ))
                    }
                } else {
                    let fSize = Int64(vals?.totalFileAllocatedSize ?? vals?.fileSize ?? 0)
                    if fSize > 0 {
                        rawEntries.append(RawEntry(
                            name: name,
                            path: itemPath,
                            isDir: false,
                            size: fSize,
                            modDate: modDate,
                            childCount: 0
                        ))
                    }
                }
            }

            rawEntries.sort { $0.size > $1.size }
            let sumBytes = rawEntries.reduce(Int64(0)) { $0 + $1.size }
            let safeTotal = max(sumBytes, 1)

            let builtNodes: [SpaceLensNode] = rawEntries.enumerated().map { idx, entry in
                SpaceLensNode(
                    id: entry.path,
                    name: entry.name,
                    path: entry.path,
                    isDirectory: entry.isDir,
                    sizeBytes: entry.size,
                    modifiedDate: entry.modDate,
                    childCount: entry.childCount,
                    fractionOfParent: Double(entry.size) / Double(safeTotal),
                    colorIndex: idx % 10
                )
            }

            return (builtNodes, sumBytes, localCache)
        }.value

        self.sizeCache = updatedCache
        self.nodes = computedNodes
        self.totalDirectoryBytes = totalBytes
        self.isScanning = false
        let formattedTotal = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        self.scanProgressText = "Analyzed \(computedNodes.count) items (\(formattedTotal)) in \(URL(fileURLWithPath: path).lastPathComponent)"
    }

    func refreshCurrentDirectory() async {
        // Invalidate cache for current root and its immediate children
        sizeCache.removeValue(forKey: currentRootPath)
        for node in nodes {
            sizeCache.removeValue(forKey: node.path)
        }
        await scanDirectory(at: currentRootPath, pushHistory: false)
    }

    func goBack() async {
        guard let previous = navigationStack.popLast() else { return }
        await scanDirectory(at: previous, pushHistory: false)
    }

    func goUpOneLevel() async {
        let parent = (currentRootPath as NSString).deletingLastPathComponent
        guard !parent.isEmpty && parent != currentRootPath else { return }
        await scanDirectory(at: parent, pushHistory: true)
    }

    func pickCustomFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Folder to Analyze in Space Lens"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: homeDir)
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await scanDirectory(at: url.path, pushHistory: true)
            }
        }
    }

    func moveNodeToTrash(_ node: SpaceLensNode) async {
        let url = URL(fileURLWithPath: node.path)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            sizeCache.removeValue(forKey: node.path)
            sizeCache.removeValue(forKey: currentRootPath)
            statusMessage = "Moved '\(node.name)' (\(node.formattedSize)) to Trash. (Rollback: Restore from Trash anytime.)"
            await scanDirectory(at: currentRootPath, pushHistory: false)
        } catch {
            statusMessage = "Could not move '\(node.name)' to Trash: \(error.localizedDescription)"
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

    nonisolated private static func fastDirectorySize(at directoryURL: URL) -> Int64 {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            guard let vals = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }
            if vals.isSymbolicLink == true { continue }
            if vals.isRegularFile == true {
                total += Int64(vals.totalFileAllocatedSize ?? vals.fileSize ?? 0)
            }
        }
        return total
    }
}
