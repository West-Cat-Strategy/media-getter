import AVFoundation
import AppKit
import SwiftUI

struct RootSplitView: View {
    @Bindable var appState: AppState
    @State private var hasEnteredWorkspace: Bool

    init(appState: AppState) {
        self._appState = Bindable(appState)
        self._hasEnteredWorkspace = State(initialValue: Self.shouldBypassGatewayForAutomation)
    }

    var body: some View {
        ZStack {
            if hasEnteredWorkspace {
                WorkspaceShell(appState: appState) {
                    workspaceView
                }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 1.02)),
                        removal: .opacity
                    ))
            } else {
                GatewayThresholdView {
                    withAnimation(.spring(response: 0.72, dampingFraction: 0.88)) {
                        hasEnteredWorkspace = true
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.96)),
                    removal: .opacity.combined(with: .scale(scale: 1.08))
                ))
            }
        }
        .preferredColorScheme(.dark)
        .alert(
            appState.alert?.title ?? "Alert",
            isPresented: Binding(
                get: { appState.alert != nil },
                set: { if !$0 { appState.alert = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                appState.alert = nil
            }
        } message: {
            Text(appState.alert?.message ?? "")
        }
    }

    @ViewBuilder
    private var workspaceView: some View {
        switch appState.selectedSection {
        case .download:
            DownloadWorkspaceView(appState: appState)
        case .xMedia:
            XMediaWorkspaceView(appState: appState)
        case .convert:
            ConvertWorkspaceView(appState: appState)
        case .trim:
            TrimWorkspaceView(appState: appState)
        case .transcribe:
            TranscribeWorkspaceView(appState: appState)
        case .queue:
            QueueWorkspaceView(appState: appState)
        case .history:
            HistoryWorkspaceView(appState: appState)
        }
    }

    private static var shouldBypassGatewayForAutomation: Bool {
        let processInfo = ProcessInfo.processInfo
        if processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }

        return processInfo.arguments.contains { $0.hasPrefix("-uitest-") }
    }
}

private struct WorkspaceShell<WorkspaceContent: View>: View {
    @Bindable var appState: AppState
    let workspaceView: WorkspaceContent

    init(appState: AppState, @ViewBuilder workspaceView: () -> WorkspaceContent) {
        self._appState = Bindable(appState)
        self.workspaceView = workspaceView()
    }

    private var pendingCount: Int {
        appState.queueStore.jobs.filter { $0.status == .pending }.count
    }

    private var runningCount: Int {
        appState.queueStore.jobs.filter { $0.status == .running }.count
    }

    private var completedCount: Int {
        appState.queueStore.jobs.filter { $0.status == .completed }.count
    }

    private var operationalStateTitle: String {
        if !appState.toolIssues.isEmpty {
            return "Attention"
        }

        if runningCount > 0 {
            return "Running"
        }

        if pendingCount > 0 {
            return "Queued"
        }

        return "Ready"
    }

    private var operationalStateDetail: String {
        if let runningJob = appState.queueStore.selectedRunningJob {
            return runningJob.request.title
        }

        if !appState.toolIssues.isEmpty {
            return "\(appState.toolIssues.count) tool issue\(appState.toolIssues.count == 1 ? "" : "s")"
        }

        return appState.bundledRuntimeSummary
    }

    var body: some View {
        ZStack {
            WorkspaceBackdrop()

            HStack(spacing: 0) {
                SidebarRail(appState: appState)
                    .frame(width: 244)

                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1)

                VStack(alignment: .leading, spacing: 22) {
                    WorkspaceTopBar(
                        appState: appState,
                        operationalStateTitle: operationalStateTitle,
                        operationalStateDetail: operationalStateDetail,
                        pendingCount: pendingCount,
                        runningCount: runningCount,
                        completedCount: completedCount
                    )

                    HStack(alignment: .top, spacing: 22) {
                        WorkspaceZone(
                            eyebrow: "Intake / Staging",
                            title: appState.selectedSection.title,
                            subtitle: appState.selectedSection.subtitle
                        ) {
                            workspaceView
                        }

                        LedgerZone(appState: appState)
                            .frame(width: 360)
                    }
                }
                .padding(26)
            }
        }
    }
}

private struct WorkspaceTopBar: View {
    @Bindable var appState: AppState
    let operationalStateTitle: String
    let operationalStateDetail: String
    let pendingCount: Int
    let runningCount: Int
    let completedCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Media Getter")
                        .font(.custom("AmericanTypewriter-Bold", size: 28))

                    Text("Atmosphere off. Work surface on.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 10) {
                    actionButton("Paste URL", systemImage: "clipboard") {
                        appState.pasteURLFromClipboard()
                    }

                    actionButton("Open File", systemImage: "folder") {
                        appState.openMediaFileForCurrentSection()
                    }

                    Button {
                        Task { await appState.startPrimaryAction() }
                    } label: {
                        Label("Start", systemImage: "play.fill")
                            .frame(minWidth: 92)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    actionButton("Cancel", systemImage: "xmark") {
                        appState.cancelSelectedJob()
                    }

                    actionButton("Reveal", systemImage: "folder.badge.gearshape") {
                        appState.revealSelectedOutput()
                    }
                }
            }

            HStack(spacing: 14) {
                MetricCard(
                    title: "Operational State",
                    value: operationalStateTitle,
                    detail: operationalStateDetail,
                    accent: operationalStateTitle == "Attention" ? .red : .white
                )

                MetricCard(
                    title: "Queued Items",
                    value: "\(pendingCount)",
                    detail: runningCount == 0 ? "No active process" : "\(runningCount) active now",
                    accent: .orange
                )

                MetricCard(
                    title: "Completed Processes",
                    value: "\(completedCount)",
                    detail: completedCount == 0 ? "Nothing closed yet" : "Finished in this session",
                    accent: .green
                )

                MetricCard(
                    title: "Runtime",
                    value: appState.isBundledRuntimeReady ? "Verified" : "Checking",
                    detail: appState.isBundledRuntimeReady ? "Bundled tools are ready" : appState.bundledRuntimeSummary,
                    accent: appState.isBundledRuntimeReady ? .mint : .yellow
                )
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(minWidth: 96)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

private struct SidebarRail: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Gateway")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Text("Workspaces")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)

            VStack(spacing: 10) {
                ForEach(AppSection.allCases) { section in
                    Button {
                        appState.selectedSection = section
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: section.systemImage)
                                .frame(width: 18)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(appState.selectedSection == section ? Color.white : Color.secondary)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(section.title)
                                    .font(.system(size: 14, weight: .semibold))
                                Text(section.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(appState.selectedSection == section ? Color.white.opacity(0.12) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(
                                    appState.selectedSection == section ? Color.white.opacity(0.18) : Color.white.opacity(0.05),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityIdentifier(accessibilityIdentifier(for: section))
                }
            }
            .padding(.horizontal, 14)

            Spacer()

            StudioCard {
                Text("Default output")
                    .font(.headline)
                Text(appState.preferencesStore.defaultDownloadFolderPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 16)
        }
        .background(Color.black.opacity(0.26))
    }

    private func accessibilityIdentifier(for section: AppSection) -> String {
        switch section {
        case .download: AccessibilityID.sidebarDownload
        case .xMedia: AccessibilityID.sidebarXMedia
        case .convert: AccessibilityID.sidebarConvert
        case .trim: AccessibilityID.sidebarTrim
        case .transcribe: AccessibilityID.sidebarTranscribe
        case .queue: AccessibilityID.sidebarQueue
        case .history: AccessibilityID.sidebarHistory
        }
    }
}

private struct WorkspaceZone<Content: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let content: Content

    init(
        eyebrow: String,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(eyebrow)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(title)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(red: 0.09, green: 0.10, blue: 0.12).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct LedgerZone: View {
    @Bindable var appState: AppState

    private var recentJobs: [JobRecord] {
        Array(appState.queueStore.jobs.prefix(5))
    }

    private var recentHistory: [HistoryEntry] {
        Array(appState.historyStore.entries.prefix(5))
    }

    var body: some View {
        WorkspaceZone(
            eyebrow: "Output / Ledger",
            title: "Live Results",
            subtitle: "Queue state, recent exports, and inspection stay visible while the intake side keeps moving."
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let runningJob = appState.queueStore.selectedRunningJob ?? appState.queueStore.selectedJob {
                        StudioCard {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Current process")
                                        .font(.headline)
                                    Text(runningJob.request.title)
                                        .font(.subheadline.weight(.semibold))
                                    Text(runningJob.phase)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()
                                StatusBadge(status: runningJob.status)
                            }

                            ProgressView(value: runningJob.progress)

                            HStack {
                                Button("Open Queue") {
                                    appState.selectedSection = .queue
                                    appState.queueStore.selectedJobID = runningJob.id
                                    appState.inspectorMode = .logs
                                }

                                if runningJob.outputURL != nil {
                                    Button("Reveal Output") {
                                        appState.queueStore.selectedJobID = runningJob.id
                                        appState.revealSelectedOutput()
                                    }
                                }
                            }
                        }
                    }

                    StudioCard {
                        HStack {
                            Text("Queue ledger")
                                .font(.headline)
                            Spacer()
                            Text("\(appState.queueStore.jobs.count) total")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if recentJobs.isEmpty {
                            Text("No queued jobs. The machine is behaving for once.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(recentJobs) { job in
                                Button {
                                    appState.selectedSection = .queue
                                    appState.queueStore.selectedJobID = job.id
                                    appState.inspectorMode = job.request.kind == .transcribe ? .transcript : .logs
                                } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(job.request.title)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Text(job.phase)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                            ProgressView(value: job.progress)
                                                .tint(Color(nsColor: job.status.tint))
                                        }

                                        Spacer()
                                        StatusBadge(status: job.status)
                                    }
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    StudioCard {
                        HStack {
                            Text("Recent outputs")
                                .font(.headline)
                            Spacer()
                            Text("\(appState.historyStore.entries.count) stored")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if recentHistory.isEmpty {
                            Text("Completed work lands here after the first successful run.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(recentHistory) { entry in
                                VStack(alignment: .leading, spacing: 8) {
                                    Button {
                                        appState.selectedSection = .history
                                        appState.historyStore.selectedEntryID = entry.id
                                        appState.inspectorMode = entry.jobKind == .transcribe ? .transcript : .metadata
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(entry.title)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Text(entry.summary)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)

                                    HStack {
                                        Button("Load") {
                                            appState.loadHistoryEntryIntoWorkspace(entry)
                                        }

                                        if let outputURL = entry.outputURL {
                                            Button("Reveal") {
                                                FileHelpers.reveal(outputURL)
                                            }
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }

                    StudioCard {
                        InspectorPanel(appState: appState)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(accent)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct GatewayThresholdView: View {
    let onEnter: () -> Void
    @State private var isPresented = false

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [
                    Color.white.opacity(0.06),
                    Color(red: 0.05, green: 0.05, blue: 0.06),
                    .black
                ],
                center: .center,
                startRadius: 40,
                endRadius: 620
            )
            .ignoresSafeArea()

            VStack(spacing: 26) {
                VStack(spacing: 8) {
                    Text("Media Getter")
                        .font(.custom("AmericanTypewriter-Bold", size: 48))
                        .tracking(1.8)

                    Text("Click through the threshold.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button(action: onEnter) {
                    VStack(spacing: 18) {
                        GatewayVideoButton()
                            .frame(width: 316, height: 316)

                        Text("Open Workspace")
                            .font(.system(.headline, design: .rounded))

                        Text("Bundled tools, queue, history. No ceremony after this.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 18)
                }
                .buttonStyle(.plain)
                .scaleEffect(isPresented ? 1 : 0.88)
                .opacity(isPresented ? 1 : 0)
                .shadow(color: Color.white.opacity(0.08), radius: 40, y: 10)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.82)) {
                isPresented = true
            }
        }
    }
}

private struct GatewayVideoButton: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(.black)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.54), lineWidth: 1.1)
                        .blur(radius: 0.5)
                )
                .overlay(
                    Circle()
                        .trim(from: 0.03, to: 0.94)
                        .stroke(
                            Color.white.opacity(0.48),
                            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [2, 6])
                        )
                        .rotationEffect(.degrees(-11))
                        .blur(radius: 0.7)
                )
                .overlay(
                    Circle()
                        .trim(from: 0.18, to: 0.88)
                        .stroke(
                            Color.white.opacity(0.32),
                            style: StrokeStyle(lineWidth: 1.3, lineCap: .round, dash: [3, 7])
                        )
                        .rotationEffect(.degrees(22))
                )

            if let url = Bundle.main.url(forResource: "gateway-opener", withExtension: "mp4")
                ?? Bundle.main.url(forResource: "gateway-opener", withExtension: "mp4", subdirectory: "Intro") {
                GatewayVideoPlayer(url: url)
                    .clipShape(Circle())
                    .padding(20)
            } else {
                Circle()
                    .fill(Color.white.opacity(0.06))
                    .padding(20)
                    .overlay {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.1))
                Image(systemName: "arrow.right")
                    .font(.system(size: 18, weight: .bold))
            }
            .frame(width: 54, height: 54)
            .padding(22)
        }
    }
}

private struct GatewayVideoPlayer: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.wantsLayer = true
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        context.coordinator.updateFrame(for: nsView)
    }

    static func dismantleNSView(_ nsView: PlayerContainerView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        private let player = AVQueuePlayer()
        private let playerLayer = AVPlayerLayer()
        private var looper: AVPlayerLooper?

        init(url: URL) {
            let item = AVPlayerItem(url: url)
            looper = AVPlayerLooper(player: player, templateItem: item)
            player.isMuted = true
            player.actionAtItemEnd = .none
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspectFill
            player.play()
        }

        @MainActor
        func attach(to view: PlayerContainerView) {
            if let existingSublayers = view.layer?.sublayers {
                existingSublayers.forEach { $0.removeFromSuperlayer() }
            }
            view.layer?.addSublayer(playerLayer)
            updateFrame(for: view)
        }

        @MainActor
        func updateFrame(for view: PlayerContainerView) {
            playerLayer.frame = view.bounds
        }

        func stop() {
            player.pause()
            looper = nil
        }
    }
}

private final class PlayerContainerView: NSView {
    override func layout() {
        super.layout()
        layer?.sublayers?.forEach { $0.frame = bounds }
    }
}

private struct WorkspaceBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.06, blue: 0.08),
                    Color(red: 0.08, green: 0.09, blue: 0.11),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 0)
                .stroke(Color.white.opacity(0.03), lineWidth: 1)
                .background(
                    Color.clear
                        .overlay(
                            VStack(spacing: 26) {
                                ForEach(0..<28, id: \.self) { _ in
                                    Rectangle()
                                        .fill(Color.white.opacity(0.018))
                                        .frame(height: 1)
                                }
                            }
                        )
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
}

private struct InspectorPanel: View {
    let appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Inspector")
                .font(.headline)

            Picker("Inspector", selection: Binding(
                get: { appState.inspectorMode ?? .metadata },
                set: { appState.inspectorMode = $0 }
            )) {
                ForEach(InspectorMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            switch appState.inspectorMode ?? .metadata {
            case .metadata:
                if let metadata = appState.currentMetadataForInspector() {
                    MetadataSummaryCard(metadata: metadata)
                } else {
                    Text("No metadata selected yet.")
                        .foregroundStyle(.secondary)
                }
            case .preset:
                if let preset = appState.currentPresetForInspector() {
                    StudioCard {
                        Label(preset.title, systemImage: preset.systemImage)
                            .font(.headline)
                        Text(preset.summary)
                            .foregroundStyle(.secondary)
                        Text("Container: \(preset.defaultExtension.uppercased())")
                        Text("Video codec: \(preset.defaultVideoCodec ?? "Copy or none")")
                        Text("Audio codec: \(preset.defaultAudioCodec ?? "None")")
                    }
                } else {
                    Text("Pick a workflow to inspect its preset.")
                        .foregroundStyle(.secondary)
                }
            case .logs:
                let logs = appState.logsForInspector()
                if logs.isEmpty {
                    Text("Run or select a job to inspect logs.")
                        .foregroundStyle(.secondary)
                } else {
                    StudioCard {
                        ForEach(Array(logs.suffix(8).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            case .transcript:
                if let transcript = appState.transcriptPreviewForInspector(),
                   let transcriptPath = appState.transcriptPathForInspector() {
                    TranscriptPreviewCard(
                        title: appState.transcriptTitleForInspector(),
                        transcript: transcript,
                        path: transcriptPath
                    )
                } else {
                    Text("Select a subtitle or transcript file to preview it.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
