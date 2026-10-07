import SwiftUI
import AppKit
import PaddockCore

@main
struct PaddockApp: App {
    @NSApplicationDelegateAdaptor(PaddockDelegate.self) private var delegate
    @State private var store = RaceStore()
    @State private var section: AppSection = .race
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        Window("Paddock", id: "main") {
            GeometryReader { geometry in
                ContentView(store: store, section: $section, compactWindow: geometry.size.width < 1300)
            }
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
            .frame(minWidth: 980, minHeight: 650)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified)
        .commands {
            PaddockCommands(section: $section)
            CommandGroup(after: .help) {
                Link("Recorded data from Formula 1", destination: URL(string: "https://www.formula1.com")!)
                Link("Data from OpenF1", destination: URL(string: "https://openf1.org/")!)
            }
        }
        Settings { SettingsView(store: store) }
    }
}

final class PaddockDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum AppSection: String, CaseIterable, Identifiable {
    case race, calendar, replays, standings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .race: "Replay"
        case .calendar: "Calendar"
        case .replays: "Library"
        case .standings: "Championship"
        }
    }
    var icon: String {
        switch self {
        case .race: "flag.checkered"
        case .calendar: "calendar"
        case .replays: "play.rectangle"
        case .standings: "trophy"
        }
    }
}

extension Notification.Name { static let paddockNavigate = Notification.Name("PaddockNavigate") }

struct ContentView: View {
    @Bindable var store: RaceStore
    @Binding var section: AppSection
    var compactWindow: Bool
    @State private var visibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            VStack(spacing: 0) {
                List(selection: Binding<AppSection?>(get: { section }, set: { if let destination = $0 { section = destination } })) {
                    Section("Paddock") {
                        ForEach(AppSection.allCases) { section in
                            Label(section.title, systemImage: section.icon).tag(section)
                        }
                    }
                    if let next = store.calendar.first(where: { $0.date > Date() }) {
                        Section("Next on the calendar") {
                            Button {
                                section = .calendar
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(next.name.replacingOccurrences(of: " Grand Prix", with: ""))
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(2)
                                    Text(next.date, format: .dateTime.month(.abbreviated).day())
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                            }.buttonStyle(.plain)
                        }
                    }
                }.listStyle(.sidebar)
            }.navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 270)
        } detail: {
            Group {
                switch section {
                case .race: RaceView(store: store, compactWindow: compactWindow)
                case .calendar: CalendarView(store: store, onOpenSession: { section = .race })
                case .replays: LibraryView(store: store, onOpenSession: { section = .race })
                case .standings: StandingsView(store: store)
                }
            }.navigationTitle(section.title)
                .background(CoverageWindowHandler(isCoverageSelected: section == .race,
                    isReplayActive: section == .race && store.mode == .replay && !store.isLoading,
                    visibilityChanged: { store.setCoverageVisible($0) }, action: { store.togglePlayback() }))
        }
        .focusedSceneValue(\.coverageStore, section == .race ? store : nil)
        .tint(Color.f1Red)
        .task { await store.bootstrap() }
        .onAppear { store.setAppActive(NSApp.isActive) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.setAppActive(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            store.setAppActive(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .paddockNavigate)) { note in
            if let destination = note.object as? AppSection { section = destination }
        }
    }
}

private struct CoverageStoreKey: FocusedValueKey {
    typealias Value = RaceStore
}

private struct FindKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var coverageStore: RaceStore? {
        get { self[CoverageStoreKey.self] }
        set { self[CoverageStoreKey.self] = newValue }
    }

    var find: (() -> Void)? {
        get { self[FindKey.self] }
        set { self[FindKey.self] = newValue }
    }
}

private struct PaddockCommands: Commands {
    @Binding var section: AppSection
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.coverageStore) private var store
    @FocusedValue(\.find) private var find

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Replay") { show(.race) }.keyboardShortcut("1")
            Button("Open Calendar") { show(.calendar) }.keyboardShortcut("2")
            Button("Open Library") { show(.replays) }.keyboardShortcut("3")
            Button("Open Championship") { show(.standings) }.keyboardShortcut("4")
        }
        CommandMenu("Replay") {
            Button(store?.isPlaying == true ? "Pause Replay" : "Play Replay") { store?.togglePlayback() }
                .disabled(store?.mode != .replay || store?.isLoading == true)
            Button("Skip Forward One Lap") { store?.skipLap(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(store?.mode != .replay || store?.isLoading == true)
            Button("Skip Back One Lap") { store?.skipLap(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(store?.mode != .replay || store?.isLoading == true)
            Divider()
            Button("Back 10 Seconds") { store?.nudgeReplay(-10) }
                .keyboardShortcut(.leftArrow, modifiers: [.option, .command])
                .disabled(store?.mode != .replay || store?.isLoading == true)
            Button("Forward 10 Seconds") { store?.nudgeReplay(10) }
                .keyboardShortcut(.rightArrow, modifiers: [.option, .command])
                .disabled(store?.mode != .replay || store?.isLoading == true)
            Button("Restart Replay") { store?.restartReplay() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store?.mode != .replay || store?.isLoading == true)
        }
        CommandGroup(after: .textEditing) {
            Button("Find") { find?() }
                .keyboardShortcut("f")
                .disabled(find == nil)
        }
    }

    private func show(_ destination: AppSection) {
        section = destination
        openWindow(id: "main")
    }
}

struct CoverageWindowHandler: NSViewRepresentable {
    var isCoverageSelected: Bool
    var isReplayActive: Bool
    var visibilityChanged: (Bool) -> Void
    var action: () -> Void
    func makeNSView(context: Context) -> CoverageEventView { CoverageEventView() }
    func updateNSView(_ view: CoverageEventView, context: Context) {
        view.isCoverageSelected = isCoverageSelected
        view.isReplayActive = isReplayActive
        view.visibilityChanged = visibilityChanged
        view.action = action
        view.scheduleVisibilityUpdate()
    }
    static func dismantleNSView(_ view: CoverageEventView, coordinator: ()) { view.dismantle() }
}

final class CoverageEventView: NSView {
    var isCoverageSelected = false
    var isReplayActive = false
    var visibilityChanged: ((Bool) -> Void)?
    var action: (() -> Void)?
    private var monitor: Any?
    private var visibilityTask: Task<Void, Never>?
    private weak var observedWindow: NSWindow?
    private var windowClosing = false
    private var windowMiniaturizing = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        guard let window else { return }
        if observedWindow !== window {
            observedWindow = window
            windowClosing = false
            windowMiniaturizing = window.isMiniaturized
        }
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged), name: name, object: window)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillMiniaturize), name: NSWindow.willMiniaturizeNotification, object: window)
        scheduleVisibilityUpdate()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isReplayActive, let window = self.window, NSApp.keyWindow === window,
                  event.keyCode == 49,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  !(window.firstResponder is NSTextView),
                  (!(window.firstResponder is NSControl) || window.firstResponder is NSTableView) else { return event }
            guard !event.isARepeat else { return nil }
            self.action?()
            return nil
        }
    }
    @objc private func windowVisibilityChanged(_ notification: Notification) {
        if notification.name == NSWindow.didDeminiaturizeNotification { windowMiniaturizing = false }
        if notification.name == NSWindow.didMiniaturizeNotification { windowMiniaturizing = true }
        scheduleVisibilityUpdate()
    }
    @objc private func windowWillMiniaturize(_ notification: Notification) {
        windowMiniaturizing = true
        visibilityTask?.cancel()
        visibilityChanged?(false)
    }
    @objc private func windowWillClose(_ notification: Notification) {
        windowClosing = true
        visibilityTask?.cancel()
        visibilityChanged?(false)
    }
    func scheduleVisibilityUpdate() {
        visibilityTask?.cancel()
        guard let window else { return }
        visibilityTask = Task { @MainActor [weak self, weak window] in
            guard let self else { return }
            guard let window, !Task.isCancelled, self.window === window else { return }
            let visible = self.isCoverageSelected && !self.windowClosing && !self.windowMiniaturizing && window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
            self.visibilityChanged?(visible)
            self.visibilityTask = nil
        }
    }
    func dismantle() {
        let window = observedWindow
        let closing = windowClosing
        let callback = visibilityChanged
        removeObservers()
        guard window != nil else { return }
        Task { @MainActor [weak window] in
            if closing || window.map({ !$0.isVisible || $0.isMiniaturized || !$0.occlusionState.contains(.visible) }) == true {
                callback?(false)
            }
        }
    }
    func removeObservers() {
        visibilityTask?.cancel()
        visibilityTask = nil
        NotificationCenter.default.removeObserver(self)
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
    isolated deinit { removeObservers() }
}
