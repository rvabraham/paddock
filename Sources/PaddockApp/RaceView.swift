import SwiftUI
import PaddockCore

enum RacePane: String, CaseIterable {
    case replay = "Replay", timing = "Timing", analysis = "Laps", pace = "Pace", strategy = "Strategy", control = "Race control"
}

extension Notification.Name { static let paddockAnalyzeLap = Notification.Name("PaddockAnalyzeLap") }

struct RaceView: View {
    @Bindable var store: RaceStore
    let compactWindow: Bool
    @State private var pane: RacePane = .replay
    @State private var showInspector = true
    @State private var filter = ""
    @State private var includeSlowLaps = false
    @State private var showCompactInspector = false
    @State private var analyzedLap: LapSelection?
    @FocusState private var searchFocused: Bool

    var body: some View {
        GeometryReader { viewport in
            workspace.frame(width: viewport.size.width, height: viewport.size.height)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .focusedSceneValue(\.find) {
            if pane != .timing && pane != .replay { pane = .timing }
            searchFocused = true
        }
        .toolbar {
            replayToolbar
        }
        .inspector(isPresented: .constant(showInspector && !compactWindow && store.session != nil)) {
            DriverInspector(store: store).inspectorColumnWidth(min: 260, ideal: 290, max: 360)
        }
        .onChange(of: compactWindow) { _, compact in
            if !compact { showCompactInspector = false }
        }
        .onChange(of: store.session?.key) { _, _ in
            filter = ""
            analyzedLap = nil
            pane = defaultPane
        }
        .onAppear { pane = defaultPane }
        .onReceive(NotificationCenter.default.publisher(for: .paddockAnalyzeLap)) { note in
            if let lap = note.object as? LapSelection { analyzedLap = lap; pane = .analysis; showCompactInspector = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .paddockReplayLap)) { note in
            if let lap = note.object as? LapSelection {
                store.selectedDriverNumber = lap.driverNumber
                store.seekLap(lap.lap, driver: lap.driverNumber)
                pane = .replay
                if !store.isPlaying { store.togglePlayback() }
            }
        }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            if store.session != nil {
                ReplayStatusView(store: store)
                RaceHeader(store: store)
                HStack(spacing: 16) {
                    Picker("Replay view", selection: $pane) {
                        ForEach(RacePane.allCases, id: \.self) { item in
                            Text(item == .analysis && isQualifying ? "Qualifying" : item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 530)
                    Spacer(minLength: 0)
                    if pane == .timing || pane == .replay { driverSearch }
                }
                .padding(.horizontal, 18).padding(.bottom, 10)
                Divider()
                Group {
                    switch pane {
                    case .replay: TrackView(store: store, filter: filter, inspect: inspect)
                    case .timing: RaceTimingTable(store: store, filter: filter, inspect: inspect)
                    case .analysis: LapAnalysisView(store: store, requestedLap: $analyzedLap)
                    case .pace: PaceView(store: store, chosen: $store.comparisonDriverNumbers, includeSlowLaps: $includeSlowLaps)
                    case .strategy: StrategyView(store: store, inspect: inspect)
                    case .control: RaceControlView(store: store)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ReplayControls(store: store)
            } else if store.isLoading {
                openingState
            } else {
                ContentUnavailableView {
                    Label(store.errorMessage == nil ? "Choose a recorded session" : "Recording unavailable",
                          systemImage: store.errorMessage == nil ? "play.rectangle" : "exclamationmark.triangle")
                } description: {
                    Text(store.errorMessage ?? "Open your Library to download or play a recording.")
                        .frame(maxWidth: 380)
                } actions: {
                    Button("Open Library", action: openLibrary).buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ToolbarContentBuilder private var replayToolbar: some ToolbarContent {
        if store.session != nil {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Open Library", systemImage: "books.vertical", action: openLibrary)
                    .help("Choose another recorded session")
                Button {
                    if compactWindow { showCompactInspector.toggle() }
                    else { showInspector.toggle() }
                } label: { Label("Driver inspector", systemImage: "sidebar.right") }
                .help("Show or hide driver detail")
                .accessibilityValue((compactWindow ? showCompactInspector : showInspector) ? "Shown" : "Hidden")
                .popover(isPresented: $showCompactInspector, arrowEdge: .trailing) {
                    DriverInspector(store: store).frame(width: 330, height: 580)
                }
            }
        }
    }

    private var isQualifying: Bool { store.session?.isQualifying == true }
    private var defaultPane: RacePane { isQualifying ? .analysis : .replay }

    private var openingState: some View {
        VStack(spacing: 16) {
            if let progress = store.downloadProgress, progress.totalChunks > 0 {
                ProgressView(value: progress.fraction).frame(width: 220)
            } else {
                ProgressView().controlSize(.large)
            }
            Text(store.loadingLabel).font(.headline)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            if let progress = store.downloadProgress {
                Text(replayDownloadDetail(progress)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button("Cancel") { store.cancelLoading() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openLibrary() {
        NotificationCenter.default.post(name: .paddockNavigate, object: AppSection.replays)
    }

    private var driverSearch: some View {
        TextField("Find driver", text: $filter)
            .textFieldStyle(.roundedBorder)
            .focused($searchFocused)
            .frame(minWidth: 110, maxWidth: 170)
            .accessibilityLabel("Filter drivers")
            .onExitCommand { filter = ""; searchFocused = false }
    }

    private func inspect(_ number: Int) {
        store.selectedDriverNumber = number
        if compactWindow { showCompactInspector = true }
        else { showInspector = true }
    }
}

struct ReplayStatusView: View {
    @Bindable var store: RaceStore

    var body: some View {
        if let error = store.errorMessage {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityHidden(true)
                Text(error).font(.callout).textSelection(.enabled)
                Spacer()
                Button("Dismiss") { store.errorMessage = nil }.controlSize(.small)
            }
            .padding(.horizontal, 18).padding(.vertical, 10).background(Color.orange.opacity(0.08))
        }
        if store.isLoading {
            ReplayDownloadStatus(store: store)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(.quaternary.opacity(0.3))
        }
    }
}

struct ReplayDownloadStatus: View {
    let store: RaceStore
    var cancel: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let progress = store.downloadProgress {
                if progress.totalChunks > 0 { ProgressView(value: progress.fraction).frame(width: 110) }
                else { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(progress.detail).font(.callout)
                    Text(replayDownloadDetail(progress))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            } else {
                ProgressView().controlSize(.small)
                Text(store.loadingLabel).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Cancel") { if let cancel { cancel() } else { store.cancelLoading() } }
                .controlSize(.small).keyboardShortcut(.cancelAction)
        }
    }
}

private func replayDownloadDetail(_ progress: ReplayDownloadProgress) -> String {
    let size = ByteCountFormatter.string(fromByteCount: progress.downloadedBytes, countStyle: .file)
    return progress.totalChunks > 0
        ? "\(progress.fraction.formatted(.percent.precision(.fractionLength(0)))) · \(size)"
        : size
}
