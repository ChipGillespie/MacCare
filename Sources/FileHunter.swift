import Foundation
import AppKit
import CryptoKit

@MainActor
final class FileHunter: ObservableObject {
    @Published var largeFiles: [LargeFileItem] = []
    @Published var duplicateGroups: [DuplicateFileGroup] = []
    @Published var isScanning: Bool = false
    @Published var minSizeMB: Int = 25
    @Published var statusMessage: String?

    private let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

    func runScan() async {
        guard !isScanning else { return }
        isScanning = true
        statusMessage = nil
        let home = homeDir
        let minBytes = Int64(minSizeMB) * 1024 * 1024

        let (foundLarge, foundDupes) = await Task.detached(priority: .userInitiated) { () -> ([LargeFileItem], [DuplicateFileGroup]) in
            let scanRoots = [
                "\(home)/Downloads",
                "\(home)/Desktop",
                "\(home)/Documents",
                "\(home)/Movies",
                "\(home)/Music",
                "\(home)/Pictures",
                "\(home)/Projects"
            ]

            var allCandidateFiles: [LargeFileItem] = []
            var sizeBuckets: [Int64: [LargeFileItem]] = [:]
            let fm = FileManager.default
            let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]

            for root in scanRoots {
                guard fm.fileExists(atPath: root) else { continue }
                let rootURL = URL(fileURLWithPath: root)
                guard let enumerator = fm.enumerator(
                    at: rootURL,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                for case let fileURL as URL in enumerator {
                    let path = fileURL.path
                    if path.contains("/node_modules/") || path.contains("/.git/") || path.contains("/build/") {
                        enumerator.skipDescendants()
                        continue
                    }
                    guard let vals = try? fileURL.resourceValues(forKeys: resourceKeys),
                          vals.isRegularFile == true,
                          let fSize = vals.fileSize else { continue }

                    let size64 = Int64(fSize)
                    let modDate = vals.contentModificationDate ?? Date.distantPast
                    let item = LargeFileItem(
                        name: fileURL.lastPathComponent,
                        path: path,
                        sizeBytes: size64,
                        modifiedDate: modDate,
                        isSelected: false
                    )

                    if size64 >= minBytes {
                        allCandidateFiles.append(item)
                    }
                    // Consider files >= 1 MB for duplicate detection
                    if size64 >= 1_000_000 {
                        sizeBuckets[size64, default: []].append(item)
                    }
                }
            }

            let sortedLarge = allCandidateFiles.sorted { $0.sizeBytes > $1.sizeBytes }

            // Second pass: SHA-256 hash only for size buckets with >= 2 files
            var dupeGroups: [DuplicateFileGroup] = []
            for (size, items) in sizeBuckets where items.count >= 2 {
                var hashBuckets: [String: [LargeFileItem]] = [:]
                for item in items {
                    if let digest = Self.computeFastHash(path: item.path, size: size) {
                        hashBuckets[digest, default: []].append(item)
                    }
                }
                for (hash, matched) in hashBuckets where matched.count >= 2 {
                    var ordered = matched.sorted { $0.modifiedDate < $1.modifiedDate }
                    // Keep index 0 unselected (original), pre-select copies (index 1+)
                    for idx in ordered.indices {
                        ordered[idx].isSelected = (idx > 0)
                    }
                    dupeGroups.append(DuplicateFileGroup(
                        id: hash,
                        fileSizeBytes: size,
                        files: ordered
                    ))
                }
            }

            dupeGroups.sort { $0.wastedBytes > $1.wastedBytes }
            return (sortedLarge, dupeGroups)
        }.value

        self.largeFiles = foundLarge
        self.duplicateGroups = foundDupes
        self.isScanning = false
    }

    nonisolated private static func computeFastHash(path: String, size: Int64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1024 * 1024 // 1 MB
        if size <= Int64(chunkSize * 4) {
            if let data = try? handle.readToEnd() {
                hasher.update(data: data)
            } else {
                return nil
            }
        } else {
            // Hash first 2 MB + middle 1 MB + last 1 MB + exact byte size for fast, accurate fingerprinting on large media
            if let first = try? handle.read(upToCount: chunkSize * 2) {
                hasher.update(data: first)
            }
            try? handle.seek(toOffset: UInt64(size / 2))
            if let mid = try? handle.read(upToCount: chunkSize) {
                hasher.update(data: mid)
            }
            try? handle.seek(toOffset: UInt64(max(0, size - Int64(chunkSize))))
            if let last = try? handle.read(upToCount: chunkSize) {
                hasher.update(data: last)
            }
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func toggleLargeFile(_ path: String) {
        guard let idx = largeFiles.firstIndex(where: { $0.path == path }) else { return }
        largeFiles[idx].isSelected.toggle()
    }

    func toggleDuplicateFile(groupId: String, path: String) {
        guard let gIdx = duplicateGroups.firstIndex(where: { $0.id == groupId }),
              let fIdx = duplicateGroups[gIdx].files.firstIndex(where: { $0.path == path }) else { return }
        duplicateGroups[gIdx].files[fIdx].isSelected.toggle()
    }

    var selectedLargeBytes: Int64 {
        largeFiles.filter(\.isSelected).reduce(0) { $0 + $1.sizeBytes }
    }

    var selectedDuplicateBytes: Int64 {
        duplicateGroups.flatMap(\.files).filter(\.isSelected).reduce(0) { $0 + $1.sizeBytes }
    }

    func trashSelectedLargeFiles() async {
        let targets = largeFiles.filter(\.isSelected)
        await trashFiles(targets)
    }

    func trashSelectedDuplicates() async {
        let targets = duplicateGroups.flatMap(\.files).filter(\.isSelected)
        await trashFiles(targets)
    }

    private func trashFiles(_ items: [LargeFileItem]) async {
        guard !items.isEmpty else { return }
        isScanning = true
        var freed: Int64 = 0
        var count = 0
        for item in items {
            if (try? FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)) != nil {
                freed += item.sizeBytes
                count += 1
            }
        }
        isScanning = false
        await runScan()
        let formatted = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
        statusMessage = "Moved \(count) file(s) (\(formatted)) to your Trash. (Rollback: Restore from Trash anytime.)"
    }

    func revealInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}
