import Foundation

enum ReplayArchivePersistence {
    static let maximumTypedBytes = 256 * 1024 * 1024
    static func validateSampleBudget(locationCount: Int, telemetryCount: Int) throws {
        guard locationCount >= 0, telemetryCount >= 0,
              locationCount <= ReplayArchiveStore.maximumSamples, telemetryCount <= ReplayArchiveStore.maximumSamples,
              locationCount * MemoryLayout<RecordedCarSample>.stride + telemetryCount * MemoryLayout<RecordedTelemetrySample>.stride <= maximumTypedBytes else {
            throw ProviderError.invalidData("This recording exceeds the supported replay memory budget. Choose another session.")
        }
    }
    static func load(_ manifest: ReplayManifest, store: ReplayArchiveStore) throws -> ReplayDataset {
        guard manifest.chunks.count <= 4096,
              manifest.chunks.allSatisfy({ (0...ReplayArchiveStore.maximumSamples).contains($0.rowCount) }) else { throw invalid }
        let locationCount = manifest.chunks.filter { $0.format == "location-v1" }.reduce(0) { $0 + $1.rowCount }
        let telemetryCount = manifest.chunks.filter { $0.format == "telemetry-v1" }.reduce(0) { $0 + $1.rowCount }
        try validateSampleBudget(locationCount: locationCount, telemetryCount: telemetryCount)
        guard manifest.complete, let metadata = manifest.chunks.first(where: { $0.id == "archive" }),
              let data = store.read(metadata, key: manifest.session.key), metadata.format == "archive-v1",
              var archive = try? JSONDecoder().decode(ReplayArchive.self, from: data), archive.session.key == manifest.session.key,
              archive.locations.isEmpty, archive.telemetry.isEmpty else { throw invalid }
        var locations: [RecordedCarSample] = [], telemetry: [RecordedTelemetrySample] = []
        locations.reserveCapacity(locationCount); telemetry.reserveCapacity(telemetryCount)
        for chunk in manifest.chunks {
            try Task.checkCancellation()
            if chunk.format == "location-v1" {
                guard locations.count + chunk.rowCount <= ReplayArchiveStore.maximumSamples,
                      let data = store.read(chunk, key: archive.session.key) else { throw invalid }
                let decoded = try ReplaySampleCodec.locations(data)
                guard decoded.count == chunk.rowCount else { throw invalid }
                locations.append(contentsOf: decoded)
            } else if chunk.format == "telemetry-v1" {
                guard telemetry.count + chunk.rowCount <= ReplayArchiveStore.maximumSamples,
                      let data = store.read(chunk, key: archive.session.key) else { throw invalid }
                let decoded = try ReplaySampleCodec.telemetry(data)
                guard decoded.count == chunk.rowCount else { throw invalid }
                telemetry.append(contentsOf: decoded)
            }
        }
        archive.session.title = manifest.session.title
        archive.locations = locations; archive.telemetry = telemetry
        return try ReplayDataset(archive: archive)
    }

    static func save(_ archive: ReplayArchive, manifest: inout ReplayManifest, store: inout ReplayArchiveStore) throws {
        try validateSampleBudget(locationCount: archive.locations.count, telemetryCount: archive.telemetry.count)
        guard archive.session.key == manifest.session.key, archive.locations.count <= ReplayArchiveStore.maximumSamples,
              archive.telemetry.count <= ReplayArchiveStore.maximumSamples else { throw invalid }
        var metadata = archive
        metadata.locations = []; metadata.telemetry = []
        appendPlan(id: "archive", channel: "metadata", manifest: &manifest)
        try store.write(JSONEncoder().encode(metadata), rows: archive.laps.count, format: "archive-v1", id: "archive", manifest: &manifest)
        for start in stride(from: 0, to: archive.locations.count, by: 25_000) {
            try Task.checkCancellation()
            let end = min(archive.locations.count, start + 25_000), id = "location-\(start)"
            appendPlan(id: id, channel: "location", manifest: &manifest)
            try store.write(ReplaySampleCodec.encode(Array(archive.locations[start..<end])), rows: end - start,
                format: "location-v1", id: id, manifest: &manifest)
        }
        for start in stride(from: 0, to: archive.telemetry.count, by: 25_000) {
            try Task.checkCancellation()
            let end = min(archive.telemetry.count, start + 25_000), id = "telemetry-\(start)"
            appendPlan(id: id, channel: "car_data", manifest: &manifest)
            try store.write(ReplaySampleCodec.encode(Array(archive.telemetry[start..<end])), rows: end - start,
                format: "telemetry-v1", id: id, manifest: &manifest)
        }
        if archive.locations.isEmpty { manifest.unavailableChannels.append("location") }
        if archive.telemetry.isEmpty { manifest.unavailableChannels.append("car_data") }
        noteUnavailableChannels(archive, manifest: &manifest)
    }
    static func noteUnavailableChannels(_ archive: ReplayArchive, manifest: inout ReplayManifest) {
        for (channel, missing) in [("pit", archive.pits.isEmpty), ("weather", archive.weather.isEmpty),
            ("intervals", archive.intervals.isEmpty), ("position", archive.positions.isEmpty),
            ("stints", archive.stints.isEmpty), ("race_control", archive.messages.isEmpty)] where missing {
            manifest.unavailableChannels.append(channel)
        }
        manifest.unavailableChannels = Array(Set(manifest.unavailableChannels)).sorted()
    }
    private static func appendPlan(id: String, channel: String, manifest: inout ReplayManifest) {
        if !manifest.chunks.contains(where: { $0.id == id }) { manifest.chunks.append(ReplayChunk(id: id, channel: channel)) }
    }
    private static var invalid: ProviderError { .invalidData("This replay archive is damaged or incomplete. Resume its download in Library.") }
}
