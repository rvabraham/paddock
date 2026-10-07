import SwiftUI
import PaddockCore

struct RaceControlView: View {
    let store: RaceStore
    @State private var followMessages = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Race control").font(.system(size: 13, weight: .semibold))
                Text("\(store.messages.count) messages").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Toggle("Follow latest", isOn: $followMessages).toggleStyle(.switch).controlSize(.small)
            }.padding(20)
            if store.messages.isEmpty {
                ContentUnavailableView("No race-control messages yet", systemImage: "flag", description: Text("Recorded flags, investigations, and session notices appear as the replay advances."))
            } else {
                ScrollViewReader { proxy in
                    List(store.messages) { message in
                        ControlMessageRow(message: message).id(message.id)
                    }.listStyle(.inset)
                        .onChange(of: store.messages.first?.id) { _, _ in
                            if followMessages, let latest = store.messages.first { proxy.scrollTo(latest.id, anchor: .top) }
                        }
                        .onChange(of: followMessages) { _, follows in
                            if follows, let latest = store.messages.first { proxy.scrollTo(latest.id, anchor: .top) }
                        }
                }
            }
        }
    }
}
