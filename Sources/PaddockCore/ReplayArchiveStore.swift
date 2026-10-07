import Compression
import CryptoKit
import Foundation

struct ReplayChunk: Codable, Equatable, Sendable {
    var id: String
    var channel: String
    var start: Date?
    var end: Date?
    var file: String = UUID().uuidString + ".pdc"
    var checksum: String?
    var encodedBytes: Int = 0
    var decodedBytes: Int = 0
    var rowCount: Int = 0
    var format: String = "json"
}

struct ReplayManifest: Codable, Sendable {
    var version = 1
    var source: String
    var session: SessionSummary
    var createdAt = Date()
    var updatedAt = Date()
    var complete = false
    var chunks: [ReplayChunk]
    var unavailableChannels: [String] = []
    var bytes: Int64 { chunks.reduce(0) { $0 + Int64($1.encodedBytes) } }
    var completedChunks: Int { chunks.filter { $0.checksum != nil }.count }
}

struct ReplayArchiveStore: Sendable {
    let directory: URL
    var maximumBytes: Int64 = 4 * 1024 * 1024 * 1024
    var maximumSessionBytes: Int64 = 512 * 1024 * 1024
    var maximumSessions = 64
    private var storageEstimate: Int64?
    private var sessionEstimates: [Int: Int64] = [:]
    static let maximumChunkBytes = 64 * 1024 * 1024
    static let maximumSamples = 3_000_000

    init(directory: URL, maximumBytes: Int64 = 4 * 1024 * 1024 * 1024, maximumSessionBytes: Int64 = 512 * 1024 * 1024, maximumSessions: Int = 64) {
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.maximumSessionBytes = maximumSessionBytes
        self.maximumSessions = maximumSessions
    }

    mutating func begin(session: SessionSummary, source: String, chunks: [ReplayChunk], force: Bool = false) throws -> ReplayManifest {
        try validateRoot()
        storageEstimate = nil
        sessionEstimates[session.key] = nil
        guard session.key > 0, !chunks.isEmpty, chunks.count <= 4096 else { throw invalid }
        if !FileManager.default.fileExists(atPath: sessionDirectory(session.key).path) {
            guard try remainingSessionSlots() > 0 else {
                throw ProviderError.invalidData("The replay library is full. Delete a downloaded session, then try again.")
            }
        }
        if !force, var existing = manifest(session.key, pending: true) ?? manifest(session.key), existing.source == source,
           existing.session.startsAt == session.startsAt,
           Array(existing.chunks.prefix(chunks.count)).map(\.id) == chunks.map(\.id) {
            existing.complete = false
            try save(existing, pending: true)
            return existing
        }
        let manifest = ReplayManifest(source: source, session: session, chunks: chunks)
        try save(manifest, pending: true)
        discardUnreferenced(session.key)
        storageEstimate = nil
        sessionEstimates[session.key] = nil
        return manifest
    }

    func remainingSessionSlots() throws -> Int {
        try validateRoot()
        guard FileManager.default.fileExists(atPath: directory.path) else { return maximumSessions }
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return max(0, maximumSessions - entries.filter { Int($0.lastPathComponent) != nil }.count)
    }

    func manifest(_ key: Int, pending: Bool = false) -> ReplayManifest? {
        guard key > 0, (try? validateRoot()) != nil else { return nil }
        let url = sessionDirectory(key).appendingPathComponent(pending ? "download.json" : "manifest.json")
        guard let data = safeData(url, maximum: 1024 * 1024),
              let manifest = try? JSONDecoder().decode(ReplayManifest.self, from: data),
              manifest.version == 1, manifest.session.key == key, manifest.chunks.count <= 4096,
              !manifest.chunks.isEmpty, Set(manifest.chunks.map(\.id)).count == manifest.chunks.count,
              Set(manifest.chunks.map(\.file)).count == manifest.chunks.count,
              manifest.chunks.allSatisfy({ validFile($0.file) && $0.encodedBytes >= 0 && $0.encodedBytes <= Self.maximumChunkBytes + 16
                  && $0.decodedBytes >= 0 && $0.decodedBytes <= Self.maximumChunkBytes && $0.rowCount >= 0 && $0.rowCount <= Self.maximumSamples }),
              manifest.bytes <= maximumSessionBytes
        else { return nil }
        return manifest
    }

    mutating func replan(_ chunks: [ReplayChunk], session: SessionSummary, manifest: inout ReplayManifest) throws {
        guard session.key == manifest.session.key, !chunks.isEmpty, chunks.count <= 4096 else { throw invalid }
        let previous = Dictionary(uniqueKeysWithValues: manifest.chunks.map { ($0.id, $0) })
        manifest.chunks = chunks.map { plan in
            guard let saved = previous[plan.id], saved.channel == plan.channel,
                  saved.start == plan.start, saved.end == plan.end else { return plan }
            return saved
        }
        manifest.session = session
        manifest.complete = false
        try save(manifest, pending: true)
        discardUnreferenced(session.key)
        storageEstimate = nil; sessionEstimates[session.key] = nil
    }

    func read(_ chunk: ReplayChunk, key: Int) -> Data? {
        guard key > 0, validFile(chunk.file), let checksum = chunk.checksum,
              let data = safeData(sessionDirectory(key).appendingPathComponent(chunk.file), maximum: Self.maximumChunkBytes + 16),
              data.count == chunk.encodedBytes, Self.checksum(data) == checksum,
              let decoded = try? ReplayCompression.decode(data), decoded.count == chunk.decodedBytes else { return nil }
        return decoded
    }

    mutating func write(_ data: Data, rows: Int, format: String, id: String, manifest: inout ReplayManifest) throws {
        try validateRoot()
        guard let index = manifest.chunks.firstIndex(where: { $0.id == id }), data.count <= Self.maximumChunkBytes,
              rows >= 0, rows <= Self.maximumSamples else { throw invalid }
        let encoded = try ReplayCompression.encode(data)
        let folder = sessionDirectory(manifest.session.key)
        let target = folder.appendingPathComponent(manifest.chunks[index].file)
        let previousSize = fileSize(target) ?? 0
        guard try currentSessionBytes(manifest.session.key) + Int64(encoded.count) <= maximumSessionBytes,
              try currentStorageBytes() + Int64(encoded.count) <= maximumBytes else {
            throw ProviderError.invalidData("Replay storage is full. Delete a downloaded session in Settings, then resume this download.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try validateFolder(folder)
        if FileManager.default.fileExists(atPath: target.path) { try validateFile(target) }
        try encoded.write(to: target, options: .atomic)
        storageEstimate = (storageEstimate ?? 0) - Int64(previousSize) + Int64(encoded.count)
        sessionEstimates[manifest.session.key] = (sessionEstimates[manifest.session.key] ?? 0) - Int64(previousSize) + Int64(encoded.count)
        manifest.chunks[index].checksum = Self.checksum(encoded)
        manifest.chunks[index].encodedBytes = encoded.count
        manifest.chunks[index].decodedBytes = data.count
        manifest.chunks[index].rowCount = rows
        manifest.chunks[index].format = format
        manifest.updatedAt = Date()
        try save(manifest, pending: true)
    }

    mutating func finish(_ value: ReplayManifest) throws {
        var manifest = value
        for chunk in manifest.chunks {
            try Task.checkCancellation()
            guard read(chunk, key: manifest.session.key) != nil else { throw invalid }
        }
        try Task.checkCancellation()
        manifest.complete = true
        manifest.updatedAt = Date()
        try save(manifest, pending: false)
        let pending = sessionDirectory(manifest.session.key).appendingPathComponent("download.json")
        try? FileManager.default.removeItem(at: pending)
        discardUnreferenced(manifest.session.key)
        storageEstimate = nil
        sessionEstimates[manifest.session.key] = nil
    }

    func checkpoint(_ key: Int, id: String) -> Data? {
        guard let manifest = manifest(key, pending: true), let chunk = manifest.chunks.first(where: { $0.id == id }) else { return nil }
        return read(chunk, key: key)
    }

    func archives() -> [ReplayArchiveInfo] {
        guard (try? validateRoot()) != nil,
              let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return [] }
        return folders.filter({ Int($0.lastPathComponent).map { $0 > 0 } == true }).prefix(maximumSessions).compactMap { folder in
            guard let key = Int(folder.lastPathComponent), key > 0 else { return nil }
            let complete = manifest(key)
            let pending = manifest(key, pending: true)
            guard let value = pending ?? complete else { return nil }
            let validated = value.chunks.filter { chunk in
                guard chunk.checksum != nil else { return false }
                return fileSize(folder.appendingPathComponent(chunk.file)) == chunk.encodedBytes
            }
            let ready = value.complete && validated.count == value.chunks.count
            let previousReady = complete?.complete == true && complete!.chunks.allSatisfy {
                $0.checksum != nil && fileSize(folder.appendingPathComponent($0.file)) == $0.encodedBytes
            }
            return ReplayArchiveInfo(session: value.session, availability: ready ? .complete : .partial,
                downloadedBytes: validated.reduce(0) { $0 + Int64($1.encodedBytes) }, completedChunks: validated.count,
                totalChunks: value.chunks.count, updatedAt: value.updatedAt, unavailableChannels: value.unavailableChannels,
                hasCommittedArchive: previousReady)
        }.sorted { $0.session.startsAt > $1.session.startsAt }
    }

    mutating func delete(_ key: Int) throws {
        try validateRoot()
        guard key > 0 else { throw invalid }
        let folder = sessionDirectory(key)
        if FileManager.default.fileExists(atPath: folder.path) { try validateFolder(folder); try FileManager.default.removeItem(at: folder) }
        storageEstimate = nil
        sessionEstimates[key] = nil
    }

    mutating func clear() throws {
        try validateRoot()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        storageEstimate = nil
        sessionEstimates.removeAll()
    }

    private mutating func save(_ manifest: ReplayManifest, pending: Bool) throws {
        try validateRoot()
        let folder = sessionDirectory(manifest.session.key)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try validateFolder(folder)
        let target = folder.appendingPathComponent(pending ? "download.json" : "manifest.json")
        if FileManager.default.fileExists(atPath: target.path) { try validateFile(target) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        guard data.count <= 1024 * 1024 else { throw invalid }
        let previous = fileSize(target) ?? 0
        guard try currentStorageBytes() + Int64(data.count) <= maximumBytes,
              try currentSessionBytes(manifest.session.key) + Int64(data.count) <= maximumSessionBytes else {
            throw ProviderError.invalidData("Replay storage is full. Delete a downloaded session, then resume this download.")
        }
        try data.write(to: target, options: .atomic)
        storageEstimate = (storageEstimate ?? 0) - Int64(previous) + Int64(data.count)
        sessionEstimates[manifest.session.key] = (sessionEstimates[manifest.session.key] ?? 0) - Int64(previous) + Int64(data.count)
    }

    private func discardUnreferenced(_ key: Int) {
        let retained = Set((manifest(key)?.chunks ?? []).map(\.file) + (manifest(key, pending: true)?.chunks ?? []).map(\.file))
        guard let files = try? FileManager.default.contentsOfDirectory(at: sessionDirectory(key), includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for file in files where validFile(file.lastPathComponent) && !retained.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func storageBytes(at folder: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: folder.path) else { return 0 }
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey]) else { throw invalid }
        var bytes: Int64 = 0, count = 0
        for case let file as URL in enumerator {
            count += 1
            guard count <= 100_000 else { throw invalid }
            let value = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
            if value.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if value.isRegularFile == true { bytes += Int64(value.fileSize ?? 0) }
            if bytes > maximumBytes { return bytes }
        }
        return bytes
    }
    private mutating func currentStorageBytes() throws -> Int64 {
        if let storageEstimate { return storageEstimate }
        let bytes = try storageBytes(at: directory); storageEstimate = bytes; return bytes
    }
    private mutating func currentSessionBytes(_ key: Int) throws -> Int64 {
        if let bytes = sessionEstimates[key] { return bytes }
        let bytes = try storageBytes(at: sessionDirectory(key)); sessionEstimates[key] = bytes; return bytes
    }

    private func sessionDirectory(_ key: Int) -> URL { directory.appendingPathComponent(String(key), isDirectory: true) }
    private func validFile(_ name: String) -> Bool { name.hasSuffix(".pdc") && name.count <= 100 && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-._".unicodeScalars.contains($0) } }
    private func safeData(_ url: URL, maximum: Int) -> Data? {
        guard (try? validateFolder(url.deletingLastPathComponent())) != nil,
              let size = fileSize(url), size > 0, size <= maximum else { return nil }
        return try? Data(contentsOf: url)
    }
    private func fileSize(_ url: URL) -> Int? {
        guard let value = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]), value.isRegularFile == true,
              value.isSymbolicLink != true else { return nil }
        return value.fileSize
    }
    private func validateRoot() throws {
        for url in [directory, directory.deletingLastPathComponent()] where FileManager.default.fileExists(atPath: url.path) { try validateFolder(url) }
    }
    private func validateFolder(_ url: URL) throws {
        if let value = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
           value.isSymbolicLink == true || value.isDirectory == false { throw invalid }
    }
    private func validateFile(_ url: URL) throws { guard fileSize(url) != nil else { throw invalid } }
    private var invalid: ProviderError { .invalidData("The replay archive is damaged or unsupported. Delete it and download the session again.") }
    static func checksum(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

enum ReplayCompression {
    static func encode(_ data: Data) throws -> Data {
        guard data.count <= ReplayArchiveStore.maximumChunkBytes else { throw invalid }
        if data.isEmpty { return Data([80, 68, 67, 72, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) }
        var compressed = Data(count: data.count + 65536)
        let count = compressed.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                compression_encode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, output.count,
                    input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_LZFSE)
            }
        }
        let usesCompression = count > 0 && count < data.count
        var header = Data([80, 68, 67, 72, 1, usesCompression ? 1 : 0, 0, 0])
        var size = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &size) { header.append(contentsOf: $0) }
        header.append(usesCompression ? compressed.prefix(count) : data)
        return header
    }
    static func decode(_ data: Data) throws -> Data {
        guard data.count >= 16, data.prefix(5) == Data([80, 68, 67, 72, 1]), data[5] <= 1, data[6] == 0, data[7] == 0,
              data.count <= ReplayArchiveStore.maximumChunkBytes + 16 else { throw invalid }
        let size = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
        guard size <= ReplayArchiveStore.maximumChunkBytes else { throw invalid }
        if data[5] == 0 { guard data.count - 16 == Int(size) else { throw invalid }; return Data(data.dropFirst(16)) }
        guard size > 0 else { throw invalid }
        var decoded = Data(count: Int(size))
        let count = decoded.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                compression_decode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, output.count,
                    input.bindMemory(to: UInt8.self).baseAddress!.advanced(by: 16), input.count - 16, nil, COMPRESSION_LZFSE)
            }
        }
        guard count == Int(size) else { throw invalid }
        return decoded
    }
    private static var invalid: ProviderError { .invalidData("The replay chunk is damaged or unsupported.") }
}
