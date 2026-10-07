import Foundation

struct DiskCache {
    struct Entry {
        var url: URL
        var size: Int
        var modified: Date
    }
    let directory: URL
    let maximumBytes: Int
    let maximumEntries: Int
    let maximumEntryBytes: Int

    func entries() -> [Entry] {
        guard safeDirectory else { return [] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == "json", let value = try? url.resourceValues(forKeys: keys),
                  value.isRegularFile == true, value.isSymbolicLink != true,
                  let size = value.fileSize, size > 0,
                  let modified = value.contentModificationDate else { return nil }
            return Entry(url: url, size: size, modified: modified)
        }
    }

    func read(_ name: String, maxAge: TimeInterval? = nil) -> Data? {
        guard safeDirectory, valid(name), let entry = entry(name) else { return nil }
        if let maxAge {
            let age = Date().timeIntervalSince(entry.modified)
            guard maxAge.isFinite, maxAge > 0, age >= 0, age < maxAge else { return nil }
        }
        return try? Data(contentsOf: entry.url)
    }

    @discardableResult func write(_ data: Data, name: String) -> Bool {
        guard safeDirectory, valid(name), !data.isEmpty, data.count <= maximumEntryBytes, data.count <= maximumBytes else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard safeDirectory else { return false }
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            prune(keeping: name)
            return true
        } catch { return false }
    }

    func clear() throws {
        guard safeDirectory else { throw unsafeDeletion }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func remove(_ name: String) throws {
        guard safeDirectory, valid(name) else { throw unsafeDeletion }
        let target = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        guard let value = try? target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              value.isRegularFile == true, value.isSymbolicLink != true else { throw unsafeDeletion }
        try FileManager.default.removeItem(at: target)
    }

    func maintain() { prune(keeping: "") }

    func entry(_ name: String) -> Entry? {
        guard valid(name), safeDirectory else { return nil }
        let url = directory.appendingPathComponent(name)
        guard let value = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
              value.isRegularFile == true, value.isSymbolicLink != true,
              let size = value.fileSize, size > 0, size <= maximumEntryBytes,
              let modified = value.contentModificationDate else { return nil }
        return Entry(url: url, size: size, modified: modified)
    }

    private func prune(keeping name: String) {
        let files = entries().sorted { ($0.modified, $0.url.lastPathComponent) < ($1.modified, $1.url.lastPathComponent) }
        var bytes = files.reduce(0) { $0 + $1.size }, count = files.count
        for file in files where file.url.lastPathComponent != name {
            guard bytes > maximumBytes || count > maximumEntries || file.size > maximumEntryBytes else { continue }
            if (try? FileManager.default.removeItem(at: file.url)) != nil { bytes -= file.size; count -= 1 }
        }
    }

    private func valid(_ name: String) -> Bool {
        !name.isEmpty && name == URL(fileURLWithPath: name).lastPathComponent && name.hasSuffix(".json")
            && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }
    }

    private var safeDirectory: Bool {
        for url in [directory, directory.deletingLastPathComponent()] {
            if let value = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
               value.isSymbolicLink == true || value.isDirectory == false { return false }
        }
        return true
    }
    private var unsafeDeletion: ProviderError { .invalidData("Saved data could not be removed because its folder or file is unsupported.") }
}
