import SwiftUI
import PaddockCore

struct LibraryView: View {
    @Bindable var store: RaceStore
    let onOpenSession: () -> Void
    @SceneStorage("librarySeason") private var year = Calendar.current.component(.year, from: Date())
    @SceneStorage("librarySearch") private var query = ""
    @SceneStorage("libraryCategory") private var category = "Races"
    @SceneStorage("libraryDownloadedOnly") private var downloadedOnly = false
    @State private var selection: Int?
    @State private var openingKey: Int?
    @State private var openingTask: Task<Void, Never>?
    @State private var refreshing = false
    @State private var refreshRequest = UUID()
    @State private var libraryError: String?
    @State private var isVisible = false
    @FocusState private var searchFocused: Bool
    private let categories = ["All", "Races", "Qualifying", "Practice", "Sprints"]
    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }

    private var filteredSessions: [SessionSummary] {
        var all = Dictionary(store.archives.map { ($0.session.key, $0.session) }, uniquingKeysWith: { first, _ in first })
        for session in store.sessions { all[session.key] = session }
        let archives = Dictionary(store.archives.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return all.values.filter { session in
            let ended = archives[session.key] != nil || (session.endsAt.map { $0.addingTimeInterval(1800) < Date() } ?? false)
            let name = session.sessionName.lowercased()
            let matchesCategory = category == "All" || (category == "Races" && name == "race") ||
                (category == "Qualifying" && session.isQualifying) || (category == "Practice" && name.contains("practice")) ||
                (category == "Sprints" && name.contains("sprint") && !session.isQualifying)
            return session.year == year && ended && matchesCategory && (!downloadedOnly || archives[session.key] != nil) &&
                (query.isEmpty || "\(session.title) \(session.country) \(session.circuit) \(session.sessionName)".localizedStandardContains(query))
        }.sorted { $0.startsAt > $1.startsAt }
    }

    var body: some View {
        let sessions = filteredSessions
        let archives = Dictionary(store.archives.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Season", selection: $year) {
                    ForEach((2018...currentYear).reversed(), id: \.self) { Text(String($0)).tag($0) }
                }.labelsHidden().frame(width: 90)
                Picker("Session type", selection: $category) {
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 410)
                Spacer(minLength: 0)
                TextField("Search sessions", text: $query).textFieldStyle(.roundedBorder)
                    .focused($searchFocused).frame(minWidth: 120, maxWidth: 200)
                Menu {
                    Toggle("Downloads only", isOn: $downloadedOnly)
                } label: { Image(systemName: downloadedOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
                .menuStyle(.borderlessButton).frame(width: 22).help("Filter Library")
            }
            .controlSize(.small).padding(18)
            .disabled(openingKey != nil)
            if let libraryError { PaddockInlineError(message: libraryError) }
            if openingKey != nil {
                ReplayDownloadStatus(store: store, cancel: cancelOpening)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                Divider()
            }
            if sessions.isEmpty {
                if refreshing || store.isSessionsLoading {
                    ProgressView("Finding sessions…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyState
                }
            } else {
                Table(sessions, selection: $selection) {
                    TableColumn("Date") { session in
                        Text(session.startsAt.formatted(.dateTime.month(.abbreviated).day())).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }.width(min: 65, ideal: 78, max: 95)
                    TableColumn("Grand Prix") { session in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.title).fontWeight(.medium)
                            Text(session.circuit).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                    }.width(min: 145, ideal: 250)
                    TableColumn("Session") { session in Text(session.sessionName).foregroundStyle(.secondary) }
                        .width(min: 90, ideal: 125, max: 145)
                    TableColumn("Availability") { session in
                        Text(archiveLabel(archives[session.key]))
                            .font(.caption).foregroundStyle(.secondary)
                            .help(archiveDetail(archives[session.key]))
                    }.width(min: 100, ideal: 120, max: 145)
                    TableColumn("") { session in
                        let archive = archives[session.key]
                        Button(actionTitle(archive)) { beginOpening(session, download: archive?.canReplay != true) }
                            .controlSize(.small).disabled(openingKey != nil || store.isLoading)
                            .accessibilityLabel("\(actionTitle(archive)) \(session.title), \(session.sessionName)")
                    }.width(90)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: Int.self) { keys in
                    if let key = keys.first, let session = sessions.first(where: { $0.key == key }) {
                        let archive = archives[key]
                        if archive?.canReplay == true {
                            Button("Open recording", systemImage: "play") { beginOpening(session, download: false) }
                                .disabled(openingKey != nil || store.isLoading)
                        }
                        if archive?.availability == .complete {
                            Button("Redownload", systemImage: "arrow.clockwise") { beginOpening(session, download: true, force: true) }
                                .disabled(openingKey != nil || store.isLoading)
                        }
                        if archive?.availability != .complete || needsUpgrade(archive) {
                            Button(archive?.resumable == true ? "Resume download" : "Download full replay", systemImage: "arrow.down.circle") {
                                beginOpening(session, download: true)
                            }.disabled(openingKey != nil || store.isLoading)
                        }
                        if archive != nil {
                            Divider()
                            Button("Delete download", role: .destructive) { deleteDownload(key) }
                                .disabled(openingKey != nil || store.isLoading)
                        }
                    }
                } primaryAction: { keys in
                    if let key = keys.first, let session = sessions.first(where: { $0.key == key }), openingKey == nil, !store.isLoading {
                        beginOpening(session, download: archives[key]?.canReplay != true)
                    }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Spacer()
                Text("\(sessions.count) \(sessions.count == 1 ? "session" : "sessions")").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.vertical, 10)
        }
        .navigationTitle("Library")
        .toolbar {
            Button("Refresh sessions", systemImage: "arrow.clockwise") { Task { await refresh(force: true) } }
                .disabled(refreshing || openingKey != nil)
        }
        .task(id: year) { await refresh() }
        .onAppear {
            isVisible = true
            year = min(currentYear, max(2018, year))
            if !categories.contains(category) { category = "Races" }
        }
        .onDisappear {
            isVisible = false
            if openingKey != nil { cancelOpening() }
        }
        .focusedSceneValue(\.find) { searchFocused = true }
        .onChange(of: year) { _, _ in selection = nil }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(!query.isEmpty ? "No matching sessions" : downloadedOnly ? "No downloaded sessions" : "No recorded sessions",
                  systemImage: "books.vertical")
        } description: {
            Text(!query.isEmpty ? "Try another circuit, country, or session." :
                 downloadedOnly ? "Turn off Downloads only to browse sessions." :
                 libraryError != nil ? "Refresh to try again." : "Choose another season or session type.")
                .frame(maxWidth: 380)
        } actions: {
            if libraryError != nil {
                Button("Refresh") { Task { await refresh(force: true) } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func needsUpgrade(_ archive: ReplayArchiveInfo?) -> Bool { archive?.unavailableChannels.contains("full_location") == true }
    private func actionTitle(_ archive: ReplayArchiveInfo?) -> String {
        if archive?.canReplay == true { return "Replay" }
        if archive?.resumable == true { return "Resume" }
        return "Download"
    }
    private func archiveLabel(_ archive: ReplayArchiveInfo?) -> String {
        guard let archive else { return "Available" }
        if archive.availability == .partial { return archive.hasCommittedArchive ? "Partial refresh" : "Partial download" }
        if needsUpgrade(archive) { return "Timing only" }
        return "Downloaded"
    }
    private func archiveDetail(_ archive: ReplayArchiveInfo?) -> String {
        guard let archive else { return "Download to keep the recording on this Mac" }
        let size = ByteCountFormatter.string(fromByteCount: archive.downloadedBytes, countStyle: .file)
        if archive.availability == .partial {
            return "\(archive.completedChunks) of \(archive.totalChunks) saved · \(size)." +
                (archive.hasCommittedArchive ? " The previous recording is available offline." : " Resume keeps the saved data.")
        }
        let missing: [String] = archive.unavailableChannels.compactMap { channel in
            switch channel {
            case "full_location": "full-session coordinates"
            case "location": "coordinates"
            case "car_data": "telemetry"
            case "pit": "pit records"
            case "weather": "weather"
            case "intervals": "timing gaps"
            case "position": "race positions"
            case "stints": "tyre stints"
            case "race_control": "race-control messages"
            default: nil
            }
        }
        let coverage = missing.isEmpty ? "" : ". Not recorded: \(missing.joined(separator: ", "))"
        return "\(size) saved on this Mac\(coverage)"
    }
    private func deleteDownload(_ key: Int) {
        guard openingKey == nil else { return }
        Task { await store.deleteDownloadedSession(key); libraryError = store.sessionsError }
    }
    private func refresh(force: Bool = false) async {
        let request = UUID()
        refreshRequest = request
        let season = year
        refreshing = true
        defer { if refreshRequest == request { refreshing = false } }
        libraryError = nil
        await store.fetchSessions(year: season, force: force)
        guard !Task.isCancelled, refreshRequest == request else { return }
        libraryError = store.sessionsError
    }
    private func beginOpening(_ session: SessionSummary, download: Bool, force: Bool = false) {
        guard openingKey == nil, !store.isLoading else { return }
        openingKey = session.key
        libraryError = nil
        openingTask = Task {
            defer { openingKey = nil; openingTask = nil }
            if download { await store.downloadSession(session, force: force) } else { await store.loadSession(session) }
            guard !Task.isCancelled else { return }
            if isVisible, store.errorMessage == nil, store.session?.key == session.key { onOpenSession() }
            libraryError = store.errorMessage
        }
    }
    private func cancelOpening() { openingTask?.cancel(); store.cancelLoading() }
}
