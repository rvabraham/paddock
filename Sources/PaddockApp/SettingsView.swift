import SwiftUI
import PaddockCore

struct SettingsView: View {
    @Bindable var store: RaceStore
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("defaultPlaybackRate") private var defaultPlaybackRate = 1.0
    @State private var clearingDownloads = false
    @State private var downloadError: String?
    private var downloadedSessionCount: Int { store.archives.count }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }
            Section("Replay") {
                Picker("Default playback speed", selection: $defaultPlaybackRate) {
                    ForEach(replayRates, id: \.self) { Text(playbackRateLabel($0)).tag($0) }
                }
            }
            Section {
                LabeledContent("Downloaded sessions", value: "\(downloadedSessionCount)")
                HStack {
                    Text("Remove saved replay data").foregroundStyle(.secondary)
                    Spacer()
                    if clearingDownloads { ProgressView().controlSize(.small) }
                    Button("Clear downloads") {
                        Task {
                            clearingDownloads = true
                            downloadError = nil
                            await store.clearCache()
                            downloadError = store.sessionsError
                            clearingDownloads = false
                        }
                    }
                    .disabled(clearingDownloads || downloadedSessionCount == 0)
                }
                if let downloadError {
                    Label(downloadError, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Manage individual downloads in the Library.")
            }
            Section("Sources") {
                sourceLink("Session timing and telemetry", detail: "Formula 1", url: "https://www.formula1.com")
                sourceLink("Timing archive and discovery", detail: "OpenF1", url: "https://openf1.org")
                sourceLink("Calendar and standings", detail: "Jolpica F1", url: "https://github.com/jolpica/jolpica-f1")
            }
            Section("About") {
                LabeledContent("Paddock", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                Text("Recorded Formula 1 sessions for your Mac.").foregroundStyle(.secondary)
                Text("Independent of Formula 1, the FIA, and the teams. Recorded data may have gaps. No race video is included.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 570)
        .onAppear {
            if !replayRates.contains(defaultPlaybackRate) { defaultPlaybackRate = 1 }
            if !["system", "light", "dark"].contains(appearance) { appearance = "system" }
        }
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    }

    private func sourceLink(_ title: String, detail: String, url: String) -> some View {
        LabeledContent(title) {
            Link(destination: URL(string: url)!) { Label(detail, systemImage: "arrow.up.right") }
        }
    }
}
