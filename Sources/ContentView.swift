import SwiftUI
import AppKit

enum NavigationTab: String, CaseIterable, Identifiable {
    case overview = "Overview Dashboard"
    case cleanup = "Cleanup & System Junk"
    case spaceLens = "Space Lens"
    case largeAndDupes = "Large & Duplicate Files"
    case uninstaller = "App Uninstaller"
    case updater = "App Updater"
    case malware = "Malware Scanner"
    case networkPrivacy = "Network & Privacy"
    case security = "Security & Login Items"
    case schedule = "Weekly Schedule"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.bottom.50percent"
        case .cleanup: return "sparkles.rectangle.stack"
        case .spaceLens: return "chart.pie.fill"
        case .largeAndDupes: return "doc.on.doc.fill"
        case .uninstaller: return "trash.square.fill"
        case .updater: return "arrow.down.app.fill"
        case .malware: return "ant.circle.fill"
        case .networkPrivacy: return "network.badge.shield.half.filled"
        case .security: return "checkmark.shield.fill"
        case .schedule: return "calendar.badge.clock"
        }
    }
}

struct ContentView: View {
    @StateObject private var scanner = SystemScanner()
    @StateObject private var uninstaller = AppUninstaller()
    @StateObject private var fileHunter = FileHunter()
    @StateObject private var appUpdater = AppUpdater()
    @StateObject private var malwareScanner = MalwareScanner()
    @StateObject private var spaceLens = SpaceLensScanner()
    @StateObject private var networkPrivacy = NetworkPrivacyMonitor()

    @State private var selectedTab: NavigationTab = .overview
    @State private var itemPendingConfirmation: CleanupRecommendation?
    @State private var startupItemPendingRemoval: StartupItem?
    @State private var spaceLensNodePendingTrash: SpaceLensNode?
    @State private var showBatchConfirmation: Bool = false
    @State private var showUninstallConfirmation: Bool = false
    @State private var appSearchText: String = ""
    @State private var fileHunterMode: Int = 0 // 0 = Large Files, 1 = Duplicates
    @State private var networkPrivacyMode: Int = 0 // 0 = Network & Ports, 1 = Privacy & App Permissions
    @State private var networkSearchText: String = ""
    @State private var selectedPrivacyFilter: PrivacyCapability? = nil

    var activeBanner: String? {
        scanner.statusBannerMessage ?? uninstaller.statusMessage ?? fileHunter.statusMessage ?? appUpdater.statusMessage ?? malwareScanner.statusMessage ?? spaceLens.statusMessage ?? networkPrivacy.statusMessage
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MacCare 2.0")
                            .font(.headline)
                        Text("MacBook Air Suite")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)

                List(NavigationTab.allCases, selection: $selectedTab) { tab in
                    Label(tab.rawValue, systemImage: tab.icon)
                        .tag(tab)
                }
                .listStyle(.sidebar)

                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        Task { await scanner.runFullScan() }
                    } label: {
                        HStack {
                            if scanner.isScanning {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise.circle.fill")
                            }
                            Text(scanner.isScanning ? "Scanning..." : "Run Full Scan")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)
                    .disabled(scanner.isScanning)

                    Text(scanner.scanProgressText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 225, ideal: 245, max: 265)
        } detail: {
            VStack(spacing: 0) {
                if let banner = activeBanner {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.teal)
                        Text(banner)
                            .font(.subheadline)
                        Spacer()
                        Button("Dismiss") {
                            scanner.statusBannerMessage = nil
                            uninstaller.statusMessage = nil
                            fileHunter.statusMessage = nil
                            appUpdater.statusMessage = nil
                            malwareScanner.statusMessage = nil
                            spaceLens.statusMessage = nil
                            networkPrivacy.statusMessage = nil
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Color.teal.opacity(0.12))
                    Divider()
                }

                if selectedTab == .uninstaller {
                    uninstallerSection()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            switch selectedTab {
                            case .overview:
                                if let report = scanner.report {
                                    overviewSection(report: report)
                                } else {
                                    loadingPlaceholder()
                                }
                            case .cleanup:
                                if let report = scanner.report {
                                    cleanupSection(report: report)
                                } else {
                                    loadingPlaceholder()
                                }
                            case .spaceLens:
                                spaceLensSection()
                            case .largeAndDupes:
                                largeAndDuplicatesSection()
                            case .uninstaller:
                                EmptyView()
                            case .updater:
                                appUpdaterSection()
                            case .malware:
                                malwareSection()
                            case .networkPrivacy:
                                networkPrivacySection()
                            case .security:
                                if let report = scanner.report {
                                    securitySection(report: report)
                                } else {
                                    loadingPlaceholder()
                                }
                            case .schedule:
                                scheduleSection()
                            }
                        }
                        .padding(24)
                    }
                }
            }
        }
        .task {
            if scanner.report == nil {
                await scanner.runFullScan()
            } else {
                scanner.scanProgressText = "Loaded scan from \(scanner.report!.timestamp.formatted(date: .abbreviated, time: .shortened))"
            }
            if uninstaller.installedApps.isEmpty {
                await uninstaller.loadInstalledApps()
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            if newTab == .largeAndDupes && fileHunter.largeFiles.isEmpty && !fileHunter.isScanning {
                Task { await fileHunter.runScan() }
            } else if newTab == .updater && appUpdater.outdatedItems.isEmpty && !appUpdater.isChecking {
                Task { await appUpdater.checkForUpdates() }
            } else if newTab == .spaceLens && spaceLens.nodes.isEmpty && !spaceLens.isScanning {
                Task { await spaceLens.scanDirectory(at: spaceLens.currentRootPath, pushHistory: false) }
            } else if newTab == .networkPrivacy && networkPrivacy.listeningPorts.isEmpty && networkPrivacy.establishedConnections.isEmpty && !networkPrivacy.isScanning {
                Task { await networkPrivacy.runAudit() }
            }
        }
        .confirmationDialog(
            "Move Item to Trash?",
            isPresented: Binding(
                get: { spaceLensNodePendingTrash != nil },
                set: { if !$0 { spaceLensNodePendingTrash = nil } }
            ),
            presenting: spaceLensNodePendingTrash
        ) { node in
            Button("Move '\(node.name)' (\(node.formattedSize)) to Trash", role: .destructive) {
                Task { await spaceLens.moveNodeToTrash(node) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { node in
            Text("This moves '\(node.name)' (\(node.formattedSize)) to your macOS Trash so you can restore it anytime.\n\nPath: \(node.path)")
        }
        .confirmationDialog(
            "Confirm Cleanup Action",
            isPresented: Binding(
                get: { itemPendingConfirmation != nil },
                set: { if !$0 { itemPendingConfirmation = nil } }
            ),
            presenting: itemPendingConfirmation
        ) { item in
            Button(
                item.actionType == .emptyTrash
                    ? "Permanently Empty Trash (\(item.formattedSize))"
                    : "Move \(item.title) (\(item.formattedSize)) to Trash",
                role: .destructive
            ) {
                Task { await scanner.performAction(for: item) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("\(item.explanation)\n\nPath: \(item.path)")
        }
        .confirmationDialog(
            "Remove Startup / Login Item?",
            isPresented: Binding(
                get: { startupItemPendingRemoval != nil },
                set: { if !$0 { startupItemPendingRemoval = nil } }
            ),
            presenting: startupItemPendingRemoval
        ) { item in
            Button(
                item.kind == .loginItem
                    ? "Remove '\(item.name)' from Login Items"
                    : "Unload & Move '\(item.name)' to Trash",
                role: .destructive
            ) {
                Task { await scanner.removeStartupItem(item) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            if item.kind == .loginItem {
                Text("This removes '\(item.name)' from macOS Login Items so it won't launch automatically when you log in. The application itself remains in /Applications.")
            } else {
                Text("This unloads '\(item.name)' via launchctl and moves its .plist file (\(item.path)) to your Trash so you can restore it if needed.")
            }
        }
        .confirmationDialog(
            "Clean All Selected Items?",
            isPresented: $showBatchConfirmation
        ) {
            Button("Move Selected Items to Trash", role: .destructive) {
                Task { await scanner.performSelectedActions() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let selected = scanner.report?.recommendations.filter { $0.isSelected && $0.actionType != .revealOnly } ?? []
            let totalBytes = selected.reduce(0) { $0 + $1.sizeBytes }
            let formatted = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            Text("This will clean \(selected.count) selected cache/support items (\(formatted)) and move them to your macOS Trash.")
        }
        .confirmationDialog(
            "Complete App Uninstall?",
            isPresented: $showUninstallConfirmation
        ) {
            let appName = uninstaller.selectedApp?.name ?? "Application"
            let sizeStr = ByteCountFormatter.string(fromByteCount: uninstaller.totalSelectedBytes, countStyle: .file)
            Button("Quit & Move \(appName) + \(uninstaller.flatAssociatedFiles.filter(\.isSelected).count) Items (\(sizeStr)) to Trash", role: .destructive) {
                Task { await uninstaller.uninstallSelectedFiles() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let appName = uninstaller.selectedApp?.name ?? "Application"
            let adminNote = uninstaller.selectedRequiresAdmin
                ? "\n\nNote: Because \(appName) includes system-level daemons or privileged helpers in /Library, macOS will ask for your administrator password / Touch ID to unload and move them to your Trash."
                : ""
            Text("This will quit \(appName), unload any selected background LaunchAgents/Daemons, and move the selected application bundle, libraries, caches, and preferences to your macOS Trash.\(adminNote)")
        }
    }

    @ViewBuilder
    private func loadingPlaceholder() -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.3)
            Text(scanner.scanProgressText)
                .font(.headline)
            Text("Performing safe, read-only diagnostics on your MacBook Air...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    // MARK: - 1. Overview Dashboard

    @ViewBuilder
    private func overviewSection(report: ScanReport) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.metrics.macModel)
                        .font(.title.bold())
                    Text("\(report.metrics.osVersion) • Uptime: \(report.metrics.uptime) • Load: \(report.metrics.loadAverage)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Scanned \(report.timestamp.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                // Storage Card
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Storage Health", systemImage: "internaldrive.fill")
                                .font(.headline)
                                .foregroundStyle(.teal)
                            Spacer()
                            Text("\(ByteCountFormatter.string(fromByteCount: report.metrics.diskFreeBytes, countStyle: .file)) Free")
                                .font(.subheadline.bold())
                        }
                        ProgressView(value: report.metrics.diskUsedFraction)
                            .tint(report.metrics.diskUsedFraction > 0.85 ? .orange : .teal)
                        HStack {
                            Text("Used: \(ByteCountFormatter.string(fromByteCount: report.metrics.diskUsedBytes, countStyle: .file))")
                            Spacer()
                            Text("Total: \(ByteCountFormatter.string(fromByteCount: report.metrics.diskTotalBytes, countStyle: .file))")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(8)
                }

                // Battery Card
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Battery Health", systemImage: "battery.100percent.bolt")
                                .font(.headline)
                                .foregroundStyle(.green)
                            Spacer()
                            Text("Condition: \(report.metrics.batteryCondition)")
                                .font(.subheadline.bold())
                                .foregroundStyle(.green)
                        }
                        HStack(spacing: 20) {
                            metricPill(title: "Max Capacity", value: report.metrics.batteryMaxCapacity)
                            metricPill(title: "Cycle Count", value: "\(report.metrics.batteryCycleCount)")
                            metricPill(title: "Charge", value: "\(report.metrics.batteryChargePercent)%")
                        }
                    }
                    .padding(8)
                }

                // Cleanup Summary Card
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Junk, AI Clutter & Caches", systemImage: "sparkles")
                                .font(.headline)
                                .foregroundStyle(.orange)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: report.totalCleanableBytes, countStyle: .file))
                                .font(.title3.bold())
                                .foregroundStyle(.orange)
                        }
                        Text("\(report.recommendations.count) items across AI caches, Xcode, Mail, Trash & System Junk.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 14) {
                            Button("Clean Caches →") { selectedTab = .cleanup }
                                .buttonStyle(.link)
                            Button("Space Lens →") { selectedTab = .spaceLens }
                                .buttonStyle(.link)
                            Button("Large & Duplicate Files →") { selectedTab = .largeAndDupes }
                                .buttonStyle(.link)
                        }
                    }
                    .padding(8)
                }

                // Security Summary Card
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Security, Login & Background Items", systemImage: "checkmark.shield.fill")
                                .font(.headline)
                                .foregroundStyle(report.security.allSecure ? .green : .orange)
                            Spacer()
                            Text(report.security.allSecure ? "Protected" : "Review Items")
                                .font(.subheadline.bold())
                                .foregroundStyle(report.security.allSecure ? .green : .orange)
                        }
                        let loginCount = report.security.startupItems.filter { $0.kind == .loginItem }.count
                        let agentCount = report.security.startupItems.count - loginCount
                        Text("\(loginCount) Login Items • \(agentCount) LaunchAgents/Daemons • XProtect \(report.security.xprotectVersion)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 14) {
                            Button("Manage Login Items →") { selectedTab = .security }
                                .buttonStyle(.link)
                            Button("Network & Privacy Audit →") { selectedTab = .networkPrivacy }
                                .buttonStyle(.link)
                        }
                    }
                    .padding(8)
                }
            }

            // Memory & Top CPU Processes
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Memory & Active Processes", systemImage: "memorychip")
                            .font(.headline)
                        Spacer()
                        Text(String(format: "Active + Wired: %.1f GB / %d GB (Compressed: %.1f GB)", report.metrics.memoryActiveGB, report.metrics.memoryTotalGB, report.metrics.memoryCompressedGB))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack(spacing: 16) {
                        ForEach(report.metrics.topCPUProcesses) { proc in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(proc.name)
                                    .font(.caption.bold())
                                    .lineLimit(1)
                                Text("CPU: \(proc.cpuPercent) • RAM: \(proc.memPercent)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    private func metricPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.bold())
        }
    }

    // MARK: - 2. Cleanup & System Junk (AI Clutter, Mail, Trash, Caches)

    @ViewBuilder
    private func cleanupSection(report: ScanReport) -> some View {
        let selectedActionable = report.recommendations.filter { $0.isSelected && $0.actionType != .revealOnly }
        let selectedBytes = selectedActionable.reduce(0) { $0 + $1.sizeBytes }

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("System Junk, AI Clutter, Mail & Trash")
                        .font(.title2.bold())
                    Text("Covers AI model caches, Xcode symbols, Homebrew/Google caches, Mail & Messages attachments, and Trash bins.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !selectedActionable.isEmpty {
                    Button {
                        showBatchConfirmation = true
                    } label: {
                        Label(
                            "Clean Selected (\(ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file)))",
                            systemImage: "trash.fill"
                        )
                        .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)
                    .disabled(scanner.isScanning)
                }
            }

            ForEach(RecommendationCategory.allCases, id: \.self) { category in
                let items = report.recommendations.filter { $0.category == category }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(category.rawValue)
                            .font(.headline)
                            .padding(.top, 6)

                        ForEach(items) { item in
                            recommendationRow(item: item)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recommendationRow(item: CleanupRecommendation) -> some View {
        GroupBox {
            HStack(alignment: .top, spacing: 14) {
                if item.actionType != .revealOnly {
                    Toggle("", isOn: Binding(
                        get: { item.isSelected },
                        set: { _ in scanner.toggleSelection(for: item.id) }
                    ))
                    .toggleStyle(.checkbox)
                    .padding(.top, 4)
                } else {
                    Image(systemName: "folder.badge.questionmark")
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(item.title)
                            .font(.headline)
                        safetyBadge(item.safety)
                        Spacer()
                        Text(item.formattedSize)
                            .font(.title3.bold())
                            .monospacedDigit()
                    }

                    Text(item.explanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(item.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)

                    HStack(spacing: 12) {
                        Button {
                            scanner.revealInFinder(item.path)
                        } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if item.actionType != .revealOnly {
                            Button {
                                itemPendingConfirmation = item
                            } label: {
                                Label(
                                    actionButtonTitle(for: item.actionType),
                                    systemImage: "trash"
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(item.safety == .safe ? .teal : .orange)
                            .controlSize(.small)
                            .disabled(scanner.isScanning)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(8)
        }
    }

    private func actionButtonTitle(for action: CleanupRecommendation.ActionType) -> String {
        switch action {
        case .brewCleanup: return "Run Brew Cleanup & Trash Cache"
        case .emptyTrash: return "Empty Trash Now"
        case .trashContents, .trashItem: return "Move to Trash"
        case .revealOnly: return "Reveal"
        }
    }

    private func safetyBadge(_ safety: SafetyLevel) -> some View {
        let color: Color = {
            switch safety {
            case .safe: return .green
            case .review: return .orange
            case .caution: return .blue
            }
        }()
        return Text(safety.rawValue)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    // MARK: - 3. Large & Duplicate Files Section

    @ViewBuilder
    private func largeAndDuplicatesSection() -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Large & Duplicate Files Finder")
                        .font(.title2.bold())
                    Text("Scans your Downloads, Documents, Movies, Music, Pictures, and Desktop for space hogs and exact SHA-256 duplicates.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await fileHunter.runScan() }
                } label: {
                    Label(fileHunter.isScanning ? "Scanning..." : "Rescan Files", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(fileHunter.isScanning)
            }

            HStack(spacing: 20) {
                Picker("View Mode:", selection: $fileHunterMode) {
                    Text("Large Files (\(fileHunter.largeFiles.count))").tag(0)
                    Text("Exact Duplicates (\(fileHunter.duplicateGroups.count) groups)").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 420)

                if fileHunterMode == 0 {
                    Picker("Min Size:", selection: Binding(
                        get: { fileHunter.minSizeMB },
                        set: { newVal in
                            fileHunter.minSizeMB = newVal
                            Task { await fileHunter.runScan() }
                        }
                    )) {
                        Text("> 10 MB").tag(10)
                        Text("> 25 MB").tag(25)
                        Text("> 100 MB").tag(100)
                        Text("> 500 MB").tag(500)
                    }
                    .frame(width: 170)
                }

                Spacer()

                if fileHunterMode == 0 && fileHunter.selectedLargeBytes > 0 {
                    Button {
                        Task { await fileHunter.trashSelectedLargeFiles() }
                    } label: {
                        Label(
                            "Move Selected to Trash (\(ByteCountFormatter.string(fromByteCount: fileHunter.selectedLargeBytes, countStyle: .file)))",
                            systemImage: "trash.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else if fileHunterMode == 1 && fileHunter.selectedDuplicateBytes > 0 {
                    Button {
                        Task { await fileHunter.trashSelectedDuplicates() }
                    } label: {
                        Label(
                            "Trash Selected Duplicates (\(ByteCountFormatter.string(fromByteCount: fileHunter.selectedDuplicateBytes, countStyle: .file)))",
                            systemImage: "trash.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }

            if fileHunter.isScanning {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Scanning user folders and computing SHA-256 duplicate fingerprints...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            } else if fileHunterMode == 0 {
                if fileHunter.largeFiles.isEmpty {
                    Text("No files larger than \(fileHunter.minSizeMB) MB found in your user folders.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 40)
                } else {
                    ForEach(fileHunter.largeFiles) { item in
                        GroupBox {
                            HStack(spacing: 12) {
                                Toggle("", isOn: Binding(
                                    get: { item.isSelected },
                                    set: { _ in fileHunter.toggleLargeFile(item.path) }
                                ))
                                .toggleStyle(.checkbox)

                                Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                                    .resizable()
                                    .frame(width: 28, height: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.subheadline.bold())
                                    Text("\(item.path) • Modified \(item.modifiedDate.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Text(item.formattedSize)
                                    .font(.headline.monospacedDigit())
                                Button("Reveal") {
                                    fileHunter.revealInFinder(item.path)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(6)
                        }
                    }
                }
            } else {
                if fileHunter.duplicateGroups.isEmpty {
                    GroupBox {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.title)
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("No Exact Duplicate Files (> 1 MB) Found!")
                                    .font(.headline)
                                Text("Your Downloads, Documents, Movies, Music, Pictures, and Desktop folders are free of large duplicate files.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(12)
                    }
                } else {
                    ForEach(fileHunter.duplicateGroups) { group in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label("\(group.files.count) Identical Copies (\(group.formattedEachSize) each)", systemImage: "doc.on.doc.fill")
                                        .font(.headline)
                                        .foregroundStyle(.orange)
                                    Spacer()
                                    Text("Reclaimable: \(group.formattedWastedSize)")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.orange)
                                }
                                Divider()
                                ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                                    HStack(spacing: 10) {
                                        Toggle("", isOn: Binding(
                                            get: { file.isSelected },
                                            set: { _ in fileHunter.toggleDuplicateFile(groupId: group.id, path: file.path) }
                                        ))
                                        .toggleStyle(.checkbox)

                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(file.name)
                                                    .font(.subheadline.bold())
                                                if index == 0 {
                                                    Text("Keep Original")
                                                        .font(.caption2.bold())
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 1)
                                                        .background(Color.green.opacity(0.15))
                                                        .foregroundStyle(.green)
                                                        .clipShape(Capsule())
                                                } else {
                                                    Text("Duplicate Copy")
                                                        .font(.caption2.bold())
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 1)
                                                        .background(Color.orange.opacity(0.15))
                                                        .foregroundStyle(.orange)
                                                        .clipShape(Capsule())
                                                }
                                            }
                                            Text(file.path)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .textSelection(.enabled)
                                        }
                                        Spacer()
                                        Button("Reveal") {
                                            fileHunter.revealInFinder(file.path)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                            .padding(6)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 4. App Uninstaller Section

    @ViewBuilder
    private func uninstallerSection() -> some View {
        let filteredApps = uninstaller.installedApps.filter {
            appSearchText.isEmpty ||
            $0.name.localizedCaseInsensitiveContains(appSearchText) ||
            $0.bundleId.localizedCaseInsensitiveContains(appSearchText)
        }

        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Installed Apps (\(uninstaller.installedApps.count))")
                        .font(.headline)
                    Spacer()
                    Button {
                        uninstaller.pickCustomApp()
                    } label: {
                        Label("Choose App...", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        Task { await uninstaller.loadInstalledApps() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                TextField("Search apps by name or bundle ID...", text: $appSearchText)
                    .textFieldStyle(.roundedBorder)

                if uninstaller.isScanningApps {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Scanning /Applications...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filteredApps, selection: Binding(
                        get: { uninstaller.selectedApp },
                        set: { newApp in
                            if let app = newApp {
                                Task { await uninstaller.selectAndScan(app: app) }
                            }
                        }
                    )) { app in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.appPath))
                                .resizable()
                                .frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name)
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                                Text("v\(app.version) • \(app.bundleId)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(app.formattedAppSize)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                        .tag(app)
                    }
                    .listStyle(.inset)
                }
            }
            .padding(14)
            .frame(minWidth: 290, idealWidth: 320, maxWidth: 380)

            VStack(alignment: .leading, spacing: 0) {
                if let app = uninstaller.selectedApp {
                    HStack(spacing: 14) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.appPath))
                            .resizable()
                            .frame(width: 54, height: 54)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(app.name)
                                    .font(.title2.bold())
                                Text("v\(app.version)")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                            Text(app.bundleId)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(app.appPath)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            Text(ByteCountFormatter.string(fromByteCount: uninstaller.totalSelectedBytes, countStyle: .file))
                                .font(.title2.bold())
                                .foregroundStyle(.red)
                            Text("\(uninstaller.flatAssociatedFiles.filter(\.isSelected).count) of \(uninstaller.flatAssociatedFiles.count) items selected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .background(Color.primary.opacity(0.03))

                    Divider()

                    HStack(spacing: 12) {
                        Button("Select All") { uninstaller.selectAll(true) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                        Button("Deselect All") { uninstaller.selectAll(false) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                        if uninstaller.selectedRequiresAdmin {
                            Label("Includes System Daemon/Helper (Requires Admin/Touch ID)", systemImage: "lock.shield.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        Spacer()

                        Button {
                            showUninstallConfirmation = true
                        } label: {
                            HStack(spacing: 6) {
                                if uninstaller.isUninstalling {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "trash.fill")
                                }
                                Text("Clean Uninstall (\(ByteCountFormatter.string(fromByteCount: uninstaller.totalSelectedBytes, countStyle: .file)))")
                                    .fontWeight(.semibold)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(uninstaller.isUninstalling || uninstaller.flatAssociatedFiles.filter(\.isSelected).isEmpty)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    Divider()

                    if uninstaller.isScanningDetails {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Scanning libraries, containers, caches, preferences, and background daemons for \(app.name)...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(uninstaller.associatedFiles) { group in
                                    GroupBox {
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack {
                                                Label(group.kind.rawValue, systemImage: iconForKind(group.kind))
                                                    .font(.headline)
                                                    .foregroundStyle(.teal)
                                                Spacer()
                                                let groupSum = group.files.reduce(0) { $0 + $1.sizeBytes }
                                                Text(ByteCountFormatter.string(fromByteCount: groupSum, countStyle: .file))
                                                    .font(.subheadline.bold())
                                                    .foregroundStyle(.secondary)
                                            }
                                            Divider()
                                            ForEach(group.files) { file in
                                                HStack(spacing: 10) {
                                                    Toggle("", isOn: Binding(
                                                        get: { file.isSelected },
                                                        set: { _ in uninstaller.toggleFileSelection(path: file.path) }
                                                    ))
                                                    .toggleStyle(.checkbox)

                                                    VStack(alignment: .leading, spacing: 2) {
                                                        HStack(spacing: 6) {
                                                            Text(URL(fileURLWithPath: file.path).lastPathComponent)
                                                                .font(.subheadline.bold())
                                                            if file.requiresAdmin {
                                                                Text("System / Admin")
                                                                    .font(.caption2.bold())
                                                                    .padding(.horizontal, 6)
                                                                    .padding(.vertical, 1)
                                                                    .background(Color.orange.opacity(0.15))
                                                                    .foregroundStyle(.orange)
                                                                    .clipShape(Capsule())
                                                            }
                                                        }
                                                        Text(file.path)
                                                            .font(.caption2)
                                                            .foregroundStyle(.secondary)
                                                            .textSelection(.enabled)
                                                    }
                                                    Spacer()
                                                    Text(file.formattedSize)
                                                        .font(.subheadline.monospacedDigit())
                                                    Button("Reveal") {
                                                        uninstaller.revealInFinder(file.path)
                                                    }
                                                    .buttonStyle(.bordered)
                                                    .controlSize(.small)
                                                }
                                                .padding(.vertical, 3)
                                            }
                                        }
                                        .padding(6)
                                    }
                                }
                            }
                            .padding(16)
                        }
                    }
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "trash.square.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.teal)
                        Text("Select an Application to Inspect & Uninstall")
                            .font(.title3.bold())
                        Text("Pick any app on the left (or click 'Choose App...') to scan all of its hidden Application Support folders, Caches, Containers, Preferences, LaunchAgents, LaunchDaemons, and Privileged Helper Tools.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 460)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func iconForKind(_ kind: AssociatedFileKind) -> String {
        switch kind {
        case .appBundle: return "app.badge.checkmark.fill"
        case .launchDaemonOrAgent: return "gearshape.2.fill"
        case .privilegedHelper: return "lock.shield.fill"
        case .applicationSupport: return "folder.fill.badge.gearshape"
        case .container: return "shippingbox.fill"
        case .cache: return "internaldrive"
        case .preferences: return "slider.horizontal.3"
        case .savedStateAndLogs: return "doc.text.fill"
        case .receipt: return "doc.badge.gearshape"
        }
    }

    // MARK: - 5. App Updater Section

    @ViewBuilder
    private func appUpdaterSection() -> some View {
        let selectedBrewCount = appUpdater.outdatedItems.filter { $0.isSelected && $0.source != .sparkleFeed }.count

        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("App Updater & Version Checker")
                        .font(.title2.bold())
                    Text("Checks Homebrew GUI Casks (e.g., UTM), CLI tools (git, neovim, python), and Sparkle app release feeds across /Applications.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await appUpdater.checkForUpdates() }
                } label: {
                    Label(appUpdater.isChecking ? "Checking..." : "Check for Updates", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(appUpdater.isChecking || appUpdater.isUpdating)

                if selectedBrewCount > 0 {
                    Button {
                        Task { await appUpdater.updateSelectedItems() }
                    } label: {
                        HStack(spacing: 6) {
                            if appUpdater.isUpdating {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.down.circle.fill")
                            }
                            Text(appUpdater.isUpdating ? "Updating..." : "Update Selected (\(selectedBrewCount))")
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)
                    .disabled(appUpdater.isUpdating || appUpdater.isChecking)
                }
            }

            HStack {
                Text(appUpdater.progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !appUpdater.outdatedItems.isEmpty {
                    Button("Select All") { appUpdater.selectAll(true) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Deselect All") { appUpdater.selectAll(false) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if appUpdater.isChecking {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(appUpdater.progressText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            } else if appUpdater.outdatedItems.isEmpty {
                GroupBox {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("All Checked Apps & Packages Are Up to Date!")
                                .font(.headline)
                            Text("Inspected \(appUpdater.upToDateAppsCount) apps in /Applications plus your Homebrew Casks and Formulae.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                }
            } else {
                ForEach(appUpdater.outdatedItems) { item in
                    GroupBox {
                        HStack(spacing: 12) {
                            if item.source != .sparkleFeed {
                                Toggle("", isOn: Binding(
                                    get: { item.isSelected },
                                    set: { _ in appUpdater.toggleSelection(item.id) }
                                ))
                                .toggleStyle(.checkbox)
                            } else {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(.orange)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(item.name)
                                        .font(.headline)
                                    Text(item.source.rawValue)
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(item.source == .homebrewCask ? Color.teal.opacity(0.15) : Color.blue.opacity(0.15))
                                        .foregroundStyle(item.source == .homebrewCask ? .teal : .blue)
                                        .clipShape(Capsule())
                                }
                                Text("Installed: \(item.currentVersion)  →  Latest Available: \(item.latestVersion)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()

                            Button {
                                Task { await appUpdater.updateSingleItem(item) }
                            } label: {
                                Label(
                                    item.source == .sparkleFeed ? "Open App to Update" : "Update to \(item.latestVersion)",
                                    systemImage: "arrow.down.circle"
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.teal)
                            .controlSize(.small)
                            .disabled(appUpdater.isUpdating)
                        }
                        .padding(6)
                    }
                }
            }
        }
    }

    // MARK: - 6. Security, Background Daemons & Login Items Audit

    @ViewBuilder
    private func securitySection(report: ScanReport) -> some View {
        let loginItems = report.security.startupItems.filter { $0.kind == .loginItem }
        let launchItems = report.security.startupItems.filter { $0.kind != .loginItem }

        VStack(alignment: .leading, spacing: 18) {
            Text("Security, Login Items & Background Daemons")
                .font(.title2.bold())
            Text("Monitor macOS protections and make sure apps don't sneakily add Login Items or background LaunchAgents/Daemons.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                securityPillarCard(
                    title: "System Integrity (SIP)",
                    value: report.security.sipEnabled ? "Enabled" : "Disabled",
                    ok: report.security.sipEnabled,
                    detail: "Protects system files from tampering"
                )
                securityPillarCard(
                    title: "Gatekeeper",
                    value: report.security.gatekeeperEnabled ? "Enabled" : "Disabled",
                    ok: report.security.gatekeeperEnabled,
                    detail: "Verifies app notarization & developer IDs"
                )
                securityPillarCard(
                    title: "Apple XProtect & Remediator",
                    value: "\(report.security.xprotectVersion) / \(report.security.xprotectPayloadsVersion)",
                    ok: true,
                    detail: "Updated \(report.security.xprotectLastUpdated) • Built-in malware defense"
                )
            }

            // Login Items Group
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("macOS Login Items (\(loginItems.count))", systemImage: "person.badge.key.fill")
                            .font(.headline)
                            .foregroundStyle(.teal)
                        Spacer()
                        Text("Apps configured to launch automatically when you log in")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Divider()

                    if loginItems.isEmpty {
                        Text("No macOS Login Items registered.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(loginItems) { item in
                            startupItemRow(item: item)
                        }
                    }
                }
                .padding(8)
            }

            // Background LaunchAgents & Daemons Group
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Background LaunchAgents & LaunchDaemons (\(launchItems.count))", systemImage: "gearshape.2.fill")
                            .font(.headline)
                            .foregroundStyle(.teal)
                        Spacer()
                        Text("Background services in ~/Library/LaunchAgents & /Library/Launch*")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Divider()

                    ForEach(launchItems) { item in
                        startupItemRow(item: item)
                    }
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private func startupItemRow(item: StartupItem) -> some View {
        HStack {
            Image(systemName: item.isKnownTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(item.isKnownTrusted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline.bold())
                Text("\(item.scope) • Vendor: \(item.vendor) • \(item.modifiedDate)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reveal") {
                scanner.revealInFinder(item.path)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(role: .destructive) {
                startupItemPendingRemoval = item
            } label: {
                Text(item.kind == .loginItem ? "Remove Login Item" : "Unload & Trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        Divider()
    }

    private func securityPillarCard(title: String, value: String, ok: Bool, detail: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: ok ? "checkmark.shield.fill" : "xmark.shield.fill")
                        .foregroundStyle(ok ? .green : .red)
                    Text(title)
                        .font(.subheadline.bold())
                }
                Text(value)
                    .font(.title3.bold())
                    .foregroundStyle(ok ? Color.primary : Color.red)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: - 7. Weekly Schedule & Notifications

    @ViewBuilder
    private func scheduleSection() -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Weekly Background Schedule & Notifications")
                .font(.title2.bold())
            Text("MacCare uses a native macOS LaunchAgent so zero background memory is used during the week. At your scheduled time, it runs quietly, shows a notification when the scan starts, and notifies you when it finishes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("Enable Weekly Background Health & Storage Scan", isOn: Binding(
                        get: { scanner.schedule.isEnabled },
                        set: { newVal in
                            var updated = scanner.schedule
                            updated.isEnabled = newVal
                            scanner.updateSchedule(updated)
                        }
                    ))
                    .font(.headline)

                    Divider()

                    HStack(spacing: 24) {
                        Picker("Day of Week:", selection: Binding(
                            get: { scanner.schedule.weekday },
                            set: { newDay in
                                var updated = scanner.schedule
                                updated.weekday = newDay
                                scanner.updateSchedule(updated)
                            }
                        )) {
                            ForEach(ScheduleConfig.weekdays, id: \.0) { day in
                                Text(day.1).tag(day.0)
                            }
                        }
                        .frame(width: 220)

                        Picker("Hour:", selection: Binding(
                            get: { scanner.schedule.hour },
                            set: { newHour in
                                var updated = scanner.schedule
                                updated.hour = newHour
                                scanner.updateSchedule(updated)
                            }
                        )) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(String(format: "%02d:00", h)).tag(h)
                            }
                        }
                        .frame(width: 150)
                    }
                    .disabled(!scanner.schedule.isEnabled)

                    Divider()

                    HStack(spacing: 12) {
                        Button {
                            scanner.testNotificationNow()
                        } label: {
                            Label("Test Background Scan & Notifications Now", systemImage: "bell.badge.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.teal)

                        if FileManager.default.fileExists(atPath: scanner.launchAgentPath) {
                            Button {
                                scanner.revealInFinder(scanner.launchAgentPath)
                            } label: {
                                Label("Reveal LaunchAgent Plist", systemImage: "doc.text.magnifyingglass")
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Text("LaunchAgent path: \(scanner.launchAgentPath)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }
        }
    }

    // MARK: - 8. Malware Scanner Section (Apple XProtect YARA + Community YARA + Codesign)

    @ViewBuilder
    private func malwareSection() -> some View {
        let def = malwareScanner.definitionStatus
        let selectedFindings = malwareScanner.findings.filter(\.isSelected)

        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Malware & Threat Scanner (YARA + Apple XProtect)")
                        .font(.title2.bold())
                    Text("Scans files using Apple's official XProtect.yara ruleset (\(def.xprotectYaraRuleCount) rules), Community macOS Stealer/Trojan YARA rules (\(def.communityRulesCount) rules), and Apple Gatekeeper code-signature verification.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await malwareScanner.updateDefinitions() }
                } label: {
                    HStack(spacing: 6) {
                        if malwareScanner.isUpdatingDefinitions {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        }
                        Text(malwareScanner.isUpdatingDefinitions ? "Updating Definitions..." : "Update Threat Definitions")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(malwareScanner.isUpdatingDefinitions || malwareScanner.isScanning)
            }

            // Definition Status Cards
            HStack(spacing: 16) {
                securityPillarCard(
                    title: "Open-Source YARA Engine",
                    value: def.yaraVersion,
                    ok: def.yaraInstalled,
                    detail: "Fast native ARM64 pattern-matching engine (/opt/homebrew/bin/yara)"
                )
                securityPillarCard(
                    title: "Apple XProtect YARA Rules",
                    value: "\(def.xprotectYaraRuleCount) Official Rules (\(def.xprotectYaraVersion))",
                    ok: def.xprotectYaraRuleCount > 0,
                    detail: "Updated \(def.xprotectLastUpdated) • XProtect.yara + XPScripts.yr"
                )
                securityPillarCard(
                    title: "Community macOS Threat Feed",
                    value: "\(def.communityRulesCount) Custom / Cloud Rules",
                    ok: def.communityRulesCount > 0,
                    detail: "Updated \(def.communityRulesLastUpdated) • AMOS/Poseidon/Stealer signatures"
                )
            }

            // Scan Controls Box
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 16) {
                        Picker("Scan Scope:", selection: $malwareScanner.scanMode) {
                            Text("Quick Threat Scan (Downloads, Desktop & Startup)").tag(MalwareScanMode.quick)
                            Text("Deep System Scan (User Folders + /Applications)").tag(MalwareScanMode.deep)
                        }
                        .frame(maxWidth: 460)

                        Spacer()

                        Button {
                            malwareScanner.pickCustomTargetAndScan()
                        } label: {
                            Label("Scan Custom File / Folder...", systemImage: "folder.badge.magnifyingglass")
                        }
                        .buttonStyle(.bordered)
                        .disabled(malwareScanner.isScanning)

                        Button {
                            Task { await malwareScanner.runScan() }
                        } label: {
                            HStack(spacing: 6) {
                                if malwareScanner.isScanning {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                                }
                                Text(malwareScanner.isScanning ? "Scanning..." : "Start Malware Scan")
                                    .fontWeight(.semibold)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.teal)
                        .disabled(malwareScanner.isScanning)
                    }

                    HStack {
                        Text(malwareScanner.scanProgressText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !selectedFindings.isEmpty {
                            Button(role: .destructive) {
                                Task { await malwareScanner.quarantineSelected() }
                            } label: {
                                Label("Quarantine / Move Selected (\(selectedFindings.count)) to Trash", systemImage: "trash.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        }
                    }
                }
                .padding(10)
            }

            // Scan Results Area
            if malwareScanner.isScanning {
                VStack(spacing: 14) {
                    ProgressView()
                        .scaleEffect(1.3)
                    Text(malwareScanner.scanProgressText)
                        .font(.headline)
                    Text("Matching files against \(def.xprotectYaraRuleCount + def.communityRulesCount) YARA malware signatures and verifying Apple code signatures...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 240)
            } else if let summary = malwareScanner.lastScanSummary {
                if malwareScanner.findings.isEmpty {
                    GroupBox {
                        HStack(spacing: 14) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 38))
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("No Malware or Suspicious Binaries Detected!")
                                    .font(.title3.bold())
                                    .foregroundStyle(.green)
                                Text(summary)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(14)
                    }
                } else {
                    Text(summary)
                        .font(.headline)
                        .foregroundStyle(.red)

                    ForEach(malwareScanner.findings) { finding in
                        GroupBox {
                            HStack(alignment: .top, spacing: 12) {
                                Toggle("", isOn: Binding(
                                    get: { finding.isSelected },
                                    set: { _ in malwareScanner.toggleFinding(finding.id) }
                                ))
                                .toggleStyle(.checkbox)
                                .padding(.top, 4)

                                Image(systemName: "exclamationmark.shield.fill")
                                    .font(.title2)
                                    .foregroundStyle(finding.severity == .critical ? .red : .orange)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(finding.ruleName)
                                            .font(.headline)
                                        Text(finding.severity.rawValue)
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 2)
                                            .background(Color.red.opacity(0.15))
                                            .foregroundStyle(.red)
                                            .clipShape(Capsule())
                                        Text(finding.engine)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(finding.description)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text(finding.filePath)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Button("Reveal") {
                                    malwareScanner.revealInFinder(finding.filePath)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(8)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 9. Interactive Storage Visualizer (Space Lens)

    @ViewBuilder
    private func spaceLensSection() -> some View {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Space Lens — Interactive Storage Visualizer")
                        .font(.title2.bold())
                    Text("Visually explore directory sizes, drill down into folders, and reclaim space safely.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    spaceLens.pickCustomFolder()
                } label: {
                    Label("Choose Folder...", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .disabled(spaceLens.isScanning)

                Button {
                    Task { await spaceLens.refreshCurrentDirectory() }
                } label: {
                    Label(spaceLens.isScanning ? "Scanning..." : "Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .disabled(spaceLens.isScanning)
            }

            // Quick Root Presets & Navigation Controls
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Button {
                            Task { await spaceLens.goBack() }
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(spaceLens.navigationStack.isEmpty || spaceLens.isScanning)
                        .help("Go Back")

                        Button {
                            Task { await spaceLens.goUpOneLevel() }
                        } label: {
                            Label("Up", systemImage: "arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(spaceLens.currentRootPath == "/" || spaceLens.isScanning)

                        Divider().frame(height: 18)

                        Text("Quick Roots:")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)

                        ForEach([
                            ("Home (~)", home),
                            ("~/Library", "\(home)/Library"),
                            ("/Applications", "/Applications"),
                            ("~/Downloads", "\(home)/Downloads"),
                            ("~/Projects", "\(home)/Projects")
                        ], id: \.1) { preset in
                            Button(preset.0) {
                                Task { await spaceLens.scanDirectory(at: preset.1, pushHistory: true) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(spaceLens.currentRootPath == preset.1 ? .teal : .primary)
                            .disabled(spaceLens.isScanning)
                        }

                        Spacer()

                        Text(ByteCountFormatter.string(fromByteCount: spaceLens.totalDirectoryBytes, countStyle: .file))
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.teal)
                    }

                    Divider()

                    // Interactive Breadcrumb Trail
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(spaceLens.breadcrumbs.enumerated()), id: \.offset) { idx, crumb in
                                if idx > 0 {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Button {
                                    Task { await spaceLens.scanDirectory(at: crumb.path, pushHistory: true) }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: idx == 0 ? "internaldrive.fill" : "folder.fill")
                                            .font(.caption)
                                            .foregroundStyle(.teal)
                                        Text(crumb.name)
                                            .font(idx == spaceLens.breadcrumbs.count - 1 ? .caption.bold() : .caption)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(idx == spaceLens.breadcrumbs.count - 1 ? Color.teal.opacity(0.15) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                }
                                .buttonStyle(.plain)
                                .disabled(spaceLens.isScanning)
                            }
                        }
                    }
                }
                .padding(8)
            }

            if spaceLens.isScanning {
                VStack(spacing: 14) {
                    ProgressView()
                        .scaleEffect(1.3)
                    Text(spaceLens.scanProgressText)
                        .font(.headline)
                    Text("Calculating recursive folder allocations for \(spaceLens.currentRootPath)...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            } else if spaceLens.nodes.isEmpty {
                GroupBox {
                    VStack(spacing: 10) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("Directory is Empty or Protected")
                            .font(.headline)
                        Text("No readable files or folders with non-zero size found in \(spaceLens.currentRootPath).")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                }
            } else {
                // Visual Space Lens Treemap Bar & Legend Card
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Visual Space Distribution — \(URL(fileURLWithPath: spaceLens.currentRootPath).lastPathComponent)", systemImage: "chart.bar.xaxis")
                                .font(.headline)
                            Spacer()
                            Text("\(spaceLens.nodes.count) items • Total: \(ByteCountFormatter.string(fromByteCount: spaceLens.totalDirectoryBytes, countStyle: .file))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        GeometryReader { geo in
                            HStack(spacing: 2) {
                                ForEach(spaceLens.nodes.prefix(10)) { node in
                                    let width = max(4.0, geo.size.width * CGFloat(node.fractionOfParent))
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(SpaceLensScanner.palette[node.colorIndex])
                                        .frame(width: width)
                                        .help("\(node.name): \(node.formattedSize) (\(node.percentageString))")
                                        .onTapGesture {
                                            if node.isDirectory {
                                                Task { await spaceLens.scanDirectory(at: node.path, pushHistory: true) }
                                            }
                                        }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .frame(height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                        // Legend for top 8 items
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                            ForEach(spaceLens.nodes.prefix(8)) { node in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(SpaceLensScanner.palette[node.colorIndex])
                                        .frame(width: 10, height: 10)
                                    Text(node.name)
                                        .font(.caption.bold())
                                        .lineLimit(1)
                                    Spacer(minLength: 2)
                                    Text(node.percentageString)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(Color.primary.opacity(0.03))
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                        }
                    }
                    .padding(10)
                }

                // Interactive Drill-Down Directory & File Rows
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(spaceLens.nodes) { node in
                        GroupBox {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(SpaceLensScanner.palette[node.colorIndex])
                                    .frame(width: 6, height: 36)

                                Image(nsImage: NSWorkspace.shared.icon(forFile: node.path))
                                    .resizable()
                                    .frame(width: 30, height: 30)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(node.name)
                                            .font(.subheadline.bold())
                                            .lineLimit(1)
                                        if node.isDirectory {
                                            Text("Folder (\(node.childCount) items)")
                                                .font(.caption2.bold())
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .background(Color.teal.opacity(0.15))
                                                .foregroundStyle(.teal)
                                                .clipShape(Capsule())
                                        }
                                        Spacer()
                                        Text(node.percentageString)
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                        Text(node.formattedSize)
                                            .font(.headline.monospacedDigit())
                                            .frame(minWidth: 80, alignment: .trailing)
                                    }

                                    ProgressView(value: min(max(node.fractionOfParent, 0.0), 1.0))
                                        .tint(SpaceLensScanner.palette[node.colorIndex])
                                }

                                HStack(spacing: 8) {
                                    if node.isDirectory {
                                        Button {
                                            Task { await spaceLens.scanDirectory(at: node.path, pushHistory: true) }
                                        } label: {
                                            Label("Drill Down", systemImage: "arrow.right.circle.fill")
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(.teal)
                                        .controlSize(.small)
                                    }

                                    Button("Reveal") {
                                        spaceLens.revealInFinder(node.path)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Button(role: .destructive) {
                                        spaceLensNodePendingTrash = node
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .help("Move '\(node.name)' to Trash")
                                }
                            }
                            .padding(6)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 10. Network & Port Monitor / Privacy Audit

    @ViewBuilder
    private func networkPrivacySection() -> some View {
        let filteredListeners = networkPrivacy.listeningPorts.filter {
            networkSearchText.isEmpty ||
            $0.processName.localizedCaseInsensitiveContains(networkSearchText) ||
            $0.localEndpoint.localizedCaseInsensitiveContains(networkSearchText) ||
            "\($0.pid)".contains(networkSearchText)
        }

        let filteredEstablished = networkPrivacy.establishedConnections.filter {
            networkSearchText.isEmpty ||
            $0.processName.localizedCaseInsensitiveContains(networkSearchText) ||
            $0.remoteEndpoint.localizedCaseInsensitiveContains(networkSearchText) ||
            $0.localEndpoint.localizedCaseInsensitiveContains(networkSearchText) ||
            "\($0.pid)".contains(networkSearchText)
        }

        let filteredPrivacyApps = networkPrivacy.privacyEntries.filter { entry in
            let matchesCap = (selectedPrivacyFilter == nil) || entry.capabilities.contains(selectedPrivacyFilter!)
            let matchesSearch = networkSearchText.isEmpty ||
                entry.appName.localizedCaseInsensitiveContains(networkSearchText) ||
                entry.bundleId.localizedCaseInsensitiveContains(networkSearchText)
            return matchesCap && matchesSearch
        }

        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Network & Port Monitor • macOS Privacy Audit")
                        .font(.title2.bold())
                    Text("Inspect active outbound connections, listening server ports, Application Firewall state, and app hardware/privacy permissions.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await networkPrivacy.runAudit() }
                } label: {
                    Label(networkPrivacy.isScanning ? "Refreshing..." : "Refresh Audit", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .disabled(networkPrivacy.isScanning)
            }

            // Summary Pillar Cards
            HStack(spacing: 16) {
                let lanExposedCount = networkPrivacy.listeningPorts.filter(\.isWildcardBind).count
                securityPillarCard(
                    title: "Listening Ports",
                    value: "\(networkPrivacy.listeningPorts.count) Active (\(lanExposedCount) LAN-wide)",
                    ok: lanExposedCount == 0,
                    detail: lanExposedCount == 0 ? "All listeners bound to localhost" : "\(lanExposedCount) port(s) listening on *:port / 0.0.0.0"
                )
                securityPillarCard(
                    title: "Established Connections",
                    value: "\(networkPrivacy.establishedConnections.count) Outbound",
                    ok: true,
                    detail: "Live TCP/UDP sockets across running apps"
                )
                securityPillarCard(
                    title: "macOS Application Firewall",
                    value: networkPrivacy.firewallEnabled ? (networkPrivacy.stealthModeEnabled ? "Enabled (Stealth)" : "Enabled") : "Disabled",
                    ok: networkPrivacy.firewallEnabled,
                    detail: "\(networkPrivacy.activeSystemExtensionsCount) active System Extension(s)"
                )
            }

            // Mode Switcher & Filter Bar
            HStack(spacing: 16) {
                Picker("Audit View:", selection: $networkPrivacyMode) {
                    Text("Active Network & Listening Ports (\(networkPrivacy.listeningPorts.count + networkPrivacy.establishedConnections.count))").tag(0)
                    Text("App Privacy & Permissions (\(networkPrivacy.privacyEntries.count) apps)").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 480)

                TextField("Filter by app, process, port, IP, or bundle ID...", text: $networkSearchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)

                Spacer()

                if networkPrivacyMode == 0 {
                    Button {
                        networkPrivacy.openFirewallSettings()
                    } label: {
                        Label("Firewall Settings", systemImage: "flame.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button {
                        networkPrivacy.openPrivacySettings(for: selectedPrivacyFilter)
                    } label: {
                        Label("Open macOS Privacy Settings", systemImage: "hand.raised.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if networkPrivacy.isScanning {
                VStack(spacing: 14) {
                    ProgressView()
                        .scaleEffect(1.3)
                    Text("Auditing active network sockets, listening ports, and application privacy manifests...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 280)
            } else if networkPrivacyMode == 0 {
                // Listening Server Ports Group
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Listening Server Ports (\(filteredListeners.count))", systemImage: "antenna.radiowaves.left.and.right")
                                .font(.headline)
                                .foregroundStyle(.teal)
                            Spacer()
                            Text("Orange badge indicates a port accepting connections from all interfaces (* / 0.0.0.0)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Divider()

                        if filteredListeners.isEmpty {
                            Text("No matching listening ports found.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(filteredListeners) { conn in
                                networkConnectionRow(conn: conn)
                            }
                        }
                    }
                    .padding(8)
                }

                // Established Outbound Connections Group
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Active Outbound / Established Connections (\(filteredEstablished.count))", systemImage: "globe")
                                .font(.headline)
                                .foregroundStyle(.teal)
                            Spacer()
                            Text("Real-time TCP connections from running processes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Divider()

                        if filteredEstablished.isEmpty {
                            Text("No active established connections matching your filter.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(filteredEstablished) { conn in
                                networkConnectionRow(conn: conn)
                            }
                        }
                    }
                    .padding(8)
                }
            } else {
                // Privacy Capability Filter Pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button {
                            selectedPrivacyFilter = nil
                        } label: {
                            Text("All Capabilities (\(networkPrivacy.privacyEntries.count))")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.bordered)
                        .tint(selectedPrivacyFilter == nil ? .teal : .primary)
                        .controlSize(.small)

                        ForEach(PrivacyCapability.allCases) { cap in
                            let count = networkPrivacy.privacyEntries.filter { $0.capabilities.contains(cap) }.count
                            Button {
                                selectedPrivacyFilter = (selectedPrivacyFilter == cap) ? nil : cap
                            } label: {
                                Label("\(cap.rawValue) (\(count))", systemImage: cap.icon)
                                    .font(.caption.bold())
                            }
                            .buttonStyle(.bordered)
                            .tint(selectedPrivacyFilter == cap ? .teal : .primary)
                            .controlSize(.small)
                        }
                    }
                }

                // App Privacy Matrix List
                ForEach(filteredPrivacyApps) { entry in
                    GroupBox {
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.appPath))
                                .resizable()
                                .frame(width: 36, height: 36)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(entry.appName)
                                        .font(.headline)
                                    Text(entry.bundleId)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                HStack(spacing: 6) {
                                    ForEach(entry.capabilities) { cap in
                                        Label(cap.rawValue, systemImage: cap.icon)
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(Color.teal.opacity(0.14))
                                            .foregroundStyle(.teal)
                                            .clipShape(Capsule())
                                    }
                                    ForEach(entry.tccGrantedServices, id: \.self) { tcc in
                                        Text("TCC Granted: \(tcc)")
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(Color.green.opacity(0.15))
                                            .foregroundStyle(.green)
                                            .clipShape(Capsule())
                                    }
                                }
                            }

                            Spacer()

                            Button("Reveal App") {
                                networkPrivacy.revealInFinder(entry.appPath)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Privacy Settings") {
                                networkPrivacy.openPrivacySettings(for: entry.capabilities.first)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(6)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func networkConnectionRow(conn: NetworkConnectionItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: conn.isListening ? (conn.isWildcardBind ? "exclamationmark.shield.fill" : "lock.shield.fill") : "arrow.up.right.circle.fill")
                .foregroundStyle(conn.isWildcardBind ? .orange : .teal)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(conn.processName)
                        .font(.subheadline.bold())
                    Text("PID \(conn.pid)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                    Text(conn.proto)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.15))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                    if conn.isWildcardBind {
                        Text("LAN Exposed (* / 0.0.0.0)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    } else if conn.isListening {
                        Text("Localhost Only")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }

                if let binPath = conn.binaryPath {
                    Text(binPath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if conn.isListening {
                    Text("Listening on \(conn.localEndpoint)")
                        .font(.subheadline.monospacedDigit().bold())
                } else {
                    Text("\(conn.localEndpoint) → \(conn.remoteEndpoint)")
                        .font(.caption.monospacedDigit().bold())
                        .textSelection(.enabled)
                }
                Text("User: \(conn.user) • \(conn.state)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let binPath = conn.binaryPath {
                Button("Reveal") {
                    networkPrivacy.revealInFinder(binPath)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        Divider()
    }
}
