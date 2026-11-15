import AppKit
import SwiftUI

/// Reprise's main window is deliberately a calm status view, not a terminal with a
/// video list attached. The job is to answer one question at a glance: “is my next
/// premiere ready?” Detailed diagnostics remain available under Activity when needed.
struct ContentView: View {
    @ObservedObject private var engine = MonitorEngine.shared

    private enum SidebarSection: Hashable {
        case scheduled
        case incoming
        case recordings
    }

    @State private var selectedSection: SidebarSection = .scheduled
    @State private var activityIsExpanded = false
    @State private var technicalLogIsExpanded = false
    @State private var isRefreshingIncoming = false

    private var scheduledVideos: [MonitoredVideo] {
        engine.videos
            .filter { $0.status != .done }
            .sorted {
                let left = schedulePriority($0.status)
                let right = schedulePriority($1.status)
                return left == right ? $0.scheduledDate < $1.scheduledDate : left < right
            }
    }

    private func schedulePriority(_ status: VideoStatus) -> Int {
        switch status {
        case .downloadingLive: return 0
        case .downloadingVod: return 1
        case .waiting: return 2
        case .vodPending: return 3
        case .done: return 4
        }
    }

    private var completedVideos: [MonitoredVideo] {
        engine.videos
            .filter { $0.status == .done }
            .sorted { $0.scheduledDate > $1.scheduledDate }
    }

    private var isBlockedByPermissions: Bool {
        engine.permissionWarnings["download-folder"] != nil
            || engine.permissionWarnings["cookie-access"] != nil
            || engine.permissionWarnings["external-tools"] != nil
    }

    private var healthSummary: String {
        if engine.isCheckingAll { return "Checking readiness…" }
        if !engine.permissionWarnings.isEmpty {
            let count = engine.permissionWarnings.count
            return "\(count) issue\(count == 1 ? "" : "s") need attention"
        }
        if let lastCheck = engine.lastFullCheck {
            return lastCheck.problems == 0
                ? "All checks passed \(lastCheck.date.formatted(date: .omitted, time: .shortened))"
                : "\(lastCheck.problems) issue\(lastCheck.problems == 1 ? "" : "s") need attention"
        }
        return "Ready to monitor"
    }

    var body: some View {
        if isBlockedByPermissions {
            PermissionGateView()
                .frame(minWidth: 680, minHeight: 520)
        } else {
            mainContent
        }
    }

    private var mainContent: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 280)
        .frame(minWidth: 760, minHeight: 620)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    runChecks()
                } label: {
                    if engine.isCheckingAll {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Check readiness", systemImage: "checkmark.shield")
                    }
                }
                .disabled(engine.isCheckingAll)
                .help("Check folder access, browser cookies, yt-dlp, ffmpeg and disk space")

                Button {
                    engine.openDownloadFolder()
                } label: {
                    Label("Open downloads", systemImage: "folder")
                }
                .help("Open Reprise's download folder")

                Button {
                    StatusItemController.shared?.showSettingsWindow()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    StatusItemController.shared?.showAddWindow()
                } label: {
                    Label("Add premiere", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var sidebar: some View {
        // A selection-bound List looked right but did not reliably change the detail
        // pane in this AppKit-hosted menu-bar window. These are direct buttons, so a
        // click always changes the content instead of relying on List selection state.
        VStack(alignment: .leading, spacing: 5) {
            Text("YOUR PREMIERES")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 3)

            sidebarButton(
                .scheduled,
                title: "Scheduled",
                icon: "calendar",
                count: scheduledVideos.count
            )
            sidebarButton(
                .incoming,
                title: "Incoming",
                icon: "antenna.radiowaves.left.and.right",
                count: engine.discoveredVideos.count
            )
            sidebarButton(
                .recordings,
                title: "Recordings",
                icon: "archivebox",
                count: completedVideos.count
            )

            Spacer(minLength: 0)
            HStack(spacing: 7) {
                Circle()
                    .fill(engine.permissionWarnings.isEmpty ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(healthSummary)
                    .lineLimit(2)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.bar)
        }
        .padding(.top, 16)
    }

    private func sidebarButton(
        _ section: SidebarSection,
        title: String,
        icon: String,
        count: Int
    ) -> some View {
        Button {
            selectedSection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: selectedSection == section ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            .foregroundStyle(selectedSection == section ? Color.accentColor : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(selectedSection == section ? Color.accentColor.opacity(0.12) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSection {
        case .scheduled:
            scheduledContent
        case .incoming:
            incomingContent
        case .recordings:
            recordingsContent
        }
    }

    private var scheduledContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                pageHeader(
                    title: "Scheduled",
                    subtitle: "\(scheduledVideos.count) tracked · \(scheduledVideos.filter { $0.status == .downloadingLive || $0.status == .downloadingVod }.count) recording or downloading"
                )

                if !engine.permissionWarnings.isEmpty {
                    readinessWarning
                        .padding(.top, 22)
                }

                if let nextVideo = scheduledVideos.first {
                    Text(focusHeading(for: nextVideo.status))
                        .sectionHeading()

                    NextPremiereCard(
                        video: nextVideo,
                        checkLeadMinutes: engine.settings.checkLeadMinutes,
                        onCheckNow: { engine.checkNow(nextVideo) },
                        onRunPreflight: { engine.runPreflightCheckNow(nextVideo) },
                        onEdit: { StatusItemController.shared?.showAddWindow(editing: nextVideo) },
                        onReveal: { engine.revealFile(nextVideo) },
                        onDelete: { confirmDelete(nextVideo) }
                    )

                    if scheduledVideos.count > 1 {
                        Text("Other premieres")
                            .sectionHeading()
                        VStack(spacing: 0) {
                            ForEach(Array(scheduledVideos.dropFirst())) { video in
                                ScheduledVideoRow(
                                    video: video,
                                    onCheckNow: { engine.checkNow(video) },
                                    onEdit: { StatusItemController.shared?.showAddWindow(editing: video) },
                                    onDelete: { confirmDelete(video) }
                                )
                                Divider()
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No premieres scheduled",
                        systemImage: "video.badge.plus",
                        description: Text("Add a YouTube premiere and Reprise will take it from there.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 80)
                }

                if let completedVideo = completedVideos.first {
                    Text("Recently completed")
                        .sectionHeading()
                    CompletedVideoRow(video: completedVideo) {
                        engine.revealFile(completedVideo)
                    }
                }

                activityDisclosure
                    .padding(.top, 24)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Reprise")
    }

    private func focusHeading(for status: VideoStatus) -> String {
        switch status {
        case .downloadingLive: return "Recording now"
        case .downloadingVod: return "Downloading now"
        case .waiting: return "Next premiere"
        case .vodPending: return "Waiting for VOD"
        case .done: return "Completed"
        }
    }

    private var incomingContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Incoming")
                            .font(.largeTitle.weight(.semibold))
                        Text("New premieres found on channels you watch.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        refreshIncoming()
                    } label: {
                        if isRefreshingIncoming {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Check now", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshingIncoming)
                }

                if engine.discoveredVideos.isEmpty {
                    if engine.channels.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "person.2.badge.plus")
                                .font(.system(size: 34))
                                .foregroundStyle(.secondary)
                            Text("No channels watched yet")
                                .font(.title3.weight(.semibold))
                            Text("Incoming is where Reprise places new premieres it finds for you. Add a channel to start discovering them.")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 380)
                            Button {
                                StatusItemController.shared?.showSettingsWindow()
                            } label: {
                                Label("Add a channel", systemImage: "plus")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 100)
                    } else {
                        ContentUnavailableView(
                            "Nothing new right now",
                            systemImage: "antenna.radiowaves.left.and.right",
                            description: Text("Reprise checks watched channels on the interval set in Settings. Use Check now to refresh immediately.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 100)
                    }
                } else {
                    Text("FOUND ON WATCHED CHANNELS")
                        .sectionHeading()
                    VStack(spacing: 0) {
                        ForEach(engine.discoveredVideos) { discovered in
                            DiscoveredVideoRow(
                                video: discovered,
                                onDismiss: { engine.dismissDiscovered(discovered) },
                                onAdd: { StatusItemController.shared?.showAddWindow(discovered: discovered) }
                            )
                            Divider()
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Reprise")
    }

    private var recordingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                pageHeader(
                    title: "Recordings",
                    subtitle: "Completed captures stay here; the files remain in your download folder."
                )

                if completedVideos.isEmpty {
                    ContentUnavailableView(
                        "No completed recordings yet",
                        systemImage: "archivebox",
                        description: Text("Finished LIVE and VOD captures will appear here.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 100)
                } else {
                    Text("COMPLETED")
                        .sectionHeading()
                    VStack(spacing: 0) {
                        ForEach(completedVideos) { video in
                            CompletedVideoRow(video: video) {
                                engine.revealFile(video)
                            }
                            Divider()
                        }
                    }
                    Button(role: .destructive) {
                        confirmClearHistory()
                    } label: {
                        Label("Clear completed recordings from this list", systemImage: "trash")
                    }
                    .padding(.top, 20)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Reprise")
    }

    private func pageHeader(title: String, subtitle: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.largeTitle.weight(.semibold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var readinessWarning: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Reprise needs attention before the next recording.")
                    .font(.headline)
                Spacer()
                Button("Check again") {
                    runChecks()
                }
                .controlSize(.small)
                .disabled(engine.isCheckingAll)
            }
            ForEach(Array(engine.permissionWarnings.keys.sorted()), id: \.self) { key in
                HStack(alignment: .top, spacing: 8) {
                    Text(engine.permissionWarnings[key] ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let fix = ProblemFixes.fix(for: key) {
                        Button(fix.label) {
                            fix.action()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(14)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var activityDisclosure: some View {
        DisclosureGroup(isExpanded: $activityIsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ActivityCheckRow(
                    title: "Download folder",
                    detail: engine.permissionWarnings["download-folder"] ?? "Accessible"
                )
                ActivityCheckRow(
                    title: "Browser access",
                    detail: engine.permissionWarnings["cookie-access"] ?? "Ready for login-gated premieres"
                )
                ActivityCheckRow(
                    title: "Tools",
                    detail: engine.permissionWarnings["external-tools"] ?? "yt-dlp and ffmpeg are available"
                )

                DisclosureGroup("Technical log", isExpanded: $technicalLogIsExpanded) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(engine.logLines.suffix(80).enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                    .padding(.top, 6)
                }
                .font(.caption)
            }
            .padding(.top, 12)
        } label: {
            HStack {
                Label("Activity", systemImage: "waveform.path.ecg")
                    .font(.headline)
                Spacer()
                Text(healthSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private func runChecks() {
        Task {
            await engine.runAllChecks()
        }
    }

    private func refreshIncoming() {
        guard !isRefreshingIncoming else { return }
        isRefreshingIncoming = true
        Task {
            await engine.checkChannels(force: true)
            isRefreshingIncoming = false
        }
    }

    private func confirmDelete(_ video: MonitoredVideo) {
        let alert = NSAlert()
        alert.messageText = "Remove premiere?"
        alert.informativeText = "\"\(video.label)\" will no longer be tracked. Downloaded files are not touched."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            engine.removeVideo(video)
        }
    }

    private func confirmClearHistory() {
        let count = completedVideos.count
        guard count > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "Clear completed recordings?"
        alert.informativeText = "Removes \(count) finished recording\(count == 1 ? "" : "s") from this list. Downloaded files are not touched."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            engine.clearCompleted()
        }
    }
}

private struct NextPremiereCard: View {
    let video: MonitoredVideo
    let checkLeadMinutes: Double
    let onCheckNow: () -> Void
    let onRunPreflight: () -> Void
    let onEdit: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void
    @ObservedObject private var engine = MonitorEngine.shared

    private var isBusy: Bool {
        video.status == .downloadingLive || video.status == .downloadingVod
    }

    private var monitoringDate: Date {
        video.scheduledDate.addingTimeInterval(-(checkLeadMinutes * 60))
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                StatusBadge(status: video.status)
                if video.status == .waiting, video.scheduledDate > Date() {
                    Text(video.scheduledDate, style: .relative)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if isBusy, let progress = engine.downloadProgress[video.id] {
                    Text(progress)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Check now", action: onCheckNow)
                        .disabled(isBusy)
                    Button("Run pre-flight check", action: onRunPreflight)
                    Divider()
                    Button("Edit premiere", action: onEdit)
                        .disabled(isBusy)
                    Button("Show in Finder", action: onReveal)
                    Divider()
                    Button("Remove premiere", role: .destructive, action: onDelete)
                        .disabled(isBusy)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .imageScale(.large)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Actions for \(video.label)")
            }
            .padding(.bottom, 12)

            HStack(alignment: .top, spacing: 16) {
                VideoThumbnail(video: video, width: 116, height: 65)
                VStack(alignment: .leading, spacing: 5) {
                    Text(video.label)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Label(video.scheduledDate.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        if let quality = video.quality, quality != .best {
                            Text(quality.displayName)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if video.status == .vodPending {
                Divider().padding(.vertical, 14)
                VodWaitingDetails(video: video)
            } else if video.status == .waiting {
                Divider().padding(.vertical, 14)
                HStack(spacing: 12) {
                    if monitoringDate > Date() {
                        Label("Monitoring starts \(monitoringDate.formatted(date: .omitted, time: .shortened))",
                              systemImage: "clock")
                    } else {
                        Label("Monitoring for the live broadcast", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    Spacer()
                    Button("Check now", action: onCheckNow)
                        .controlSize(.small)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(StatusBadge.color(for: video.status).opacity(isBusy ? 0.42 : 0.18))
        }
    }
}

private struct ScheduledVideoRow: View {
    @ObservedObject private var engine = MonitorEngine.shared
    let video: MonitoredVideo
    let onCheckNow: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var isBusy: Bool {
        video.status == .downloadingLive || video.status == .downloadingVod
    }

    var body: some View {
        HStack(spacing: 12) {
            VideoThumbnail(video: video, width: 52, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(video.label)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(video.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if video.status == .vodPending {
                    VodWaitingDetails(video: video)
                } else if isBusy, let progress = engine.downloadProgress[video.id] {
                    Text(progress)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            StatusBadge(status: video.status)
            Menu {
                Button("Check now", action: onCheckNow).disabled(isBusy)
                Button("Edit premiere", action: onEdit).disabled(isBusy)
                Divider()
                Button("Remove premiere", role: .destructive, action: onDelete).disabled(isBusy)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Actions for \(video.label)")
        }
        .padding(.vertical, 10)
    }
}

private struct VodWaitingDetails: View {
    @ObservedObject private var engine = MonitorEngine.shared
    let video: MonitoredVideo

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(alignment: .leading, spacing: 5) {
                Text(video.vodWaitReason ?? "Waiting for YouTube to publish the VOD.")
                if let next = engine.nextVodCheck(video), next > context.date {
                    Text("Next check around \(next.formatted(date: .omitted, time: .shortened))")
                } else {
                    Text("Next check shortly")
                }
                if let livePath = engine.liveRecordingPath(video) {
                    Button("Show LIVE recording in Finder") {
                        engine.revealLiveRecording(video)
                    }
                    .help(livePath)
                } else if video.liveDone {
                    Text("LIVE recording could not be located.")
                }
                if let availableAt = engine.vodFallbackAvailableAt(video) {
                    if availableAt <= context.date {
                        Button("Download available version") {
                            engine.downloadAvailableVod(video)
                        }
                        .help("Save the available VOD even if higher-quality formats are still processing")
                    } else {
                        Text("Available-version option at \(availableAt.formatted(date: .omitted, time: .shortened))")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct CompletedVideoRow: View {
    let video: MonitoredVideo
    let onReveal: () -> Void

    private var fileSizeText: String? {
        guard let path = video.finalFilePath,
              let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 else {
            return nil
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var body: some View {
        HStack(spacing: 12) {
            VideoThumbnail(video: video, width: 52, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(video.label)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 7) {
                    Label(video.liveDone ? "LIVE + VOD" : "VOD", systemImage: "checkmark.circle.fill")
                    if let fileSizeText { Text(fileSizeText) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                // Which version actually landed, e.g. "1080p Premium · 1920×1080 ·
                // VP9 · 25 fps", plus the check against what YouTube really offered.
                HStack(spacing: 7) {
                    if let summary = video.vodVersionSummary {
                        Label(summary, systemImage: "film")
                            .textSelection(.enabled)
                            // The version is the point of this row: never truncate
                            // it ("25…"); let the confirmation shorten instead.
                            .layoutPriority(1)
                    }
                    switch video.qualityConfirmed {
                    case true?:
                        Label("Best available confirmed", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    case false?:
                        let expected = video.vodVersion?.expectedHeight.map { " (\($0)p was available)" } ?? ""
                        Label("Lower than available\(expected)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    case nil:
                        EmptyView()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Show in Finder", action: onReveal)
                .controlSize(.small)
        }
        .padding(.vertical, 10)
    }
}

private struct DiscoveredVideoRow: View {
    let video: DiscoveredVideo
    let onDismiss: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles.tv")
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(video.channelName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if let discoveredAt = video.discoveredAt {
                        Label(
                            "Found \(discoveredAt.formatted(date: .abbreviated, time: .shortened))",
                            systemImage: "clock"
                        )
                    }
                    if let scheduledDate = video.scheduledDate {
                        Label(
                            "Premieres \(scheduledDate.formatted(date: .abbreviated, time: .shortened))",
                            systemImage: "calendar"
                        )
                        .foregroundStyle(.primary)
                    } else {
                        Label("Premiere time not available yet", systemImage: "calendar.badge.questionmark")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Dismiss", action: onDismiss)
                .controlSize(.small)
            Button("Add", action: onAdd)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.vertical, 12)
    }
}

private struct VideoThumbnail: View {
    let video: MonitoredVideo
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        AsyncImage(url: video.thumbnailURL) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.secondary.opacity(0.14)
                    Image(systemName: "play.rectangle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }
}

private struct StatusBadge: View {
    let status: VideoStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon(for: status))
                .foregroundStyle(Self.color(for: status))
                .accessibilityHidden(true)
            Text(status.displayName)
        }
        .font(.caption.weight(.semibold))
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Self.color(for: status).opacity(0.12), in: Capsule())
    }

    static func color(for status: VideoStatus) -> Color {
        switch status {
        case .waiting: return .secondary
        case .downloadingLive: return .red
        case .vodPending: return .orange
        case .downloadingVod: return .blue
        case .done: return .green
        }
    }

    private func icon(for status: VideoStatus) -> String {
        switch status {
        case .waiting: return "clock"
        case .downloadingLive: return "record.circle"
        case .vodPending: return "hourglass"
        case .downloadingVod: return "arrow.down.circle"
        case .done: return "checkmark.circle.fill"
        }
    }
}

private struct ActivityCheckRow: View {
    let title: String
    let detail: String

    private var hasProblem: Bool {
        detail.lowercased().contains("can't") || detail.lowercased().contains("missing")
            || detail.lowercased().contains("fail") || detail.lowercased().contains("problem")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: hasProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(hasProblem ? Color.orange : Color.green)
            Text(title)
                .font(.caption.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

private extension View {
    func sectionHeading() -> some View {
        self
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 28)
            .padding(.bottom, 10)
    }
}
