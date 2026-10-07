import Foundation

public enum ReplayDownloadPhase: String, Codable, Sendable {
    case metadata, downloading, verifying, complete
}

public struct ReplayDownloadProgress: Sendable, Equatable {
    public var phase: ReplayDownloadPhase
    public var completedChunks: Int
    public var totalChunks: Int
    public var downloadedBytes: Int64
    public var detail: String
    public var isResuming: Bool
    public var fraction: Double { totalChunks > 0 ? min(1, Double(completedChunks) / Double(totalChunks)) : 0 }

    public init(phase: ReplayDownloadPhase, completedChunks: Int, totalChunks: Int, downloadedBytes: Int64, detail: String, isResuming: Bool) {
        self.phase = phase
        self.completedChunks = completedChunks
        self.totalChunks = totalChunks
        self.downloadedBytes = downloadedBytes
        self.detail = detail
        self.isResuming = isResuming
    }
}

public enum ReplayArchiveAvailability: String, Codable, Sendable { case complete, partial }

public struct ReplayArchiveInfo: Identifiable, Codable, Sendable, Equatable {
    public var id: Int { session.key }
    public var session: SessionSummary
    public var availability: ReplayArchiveAvailability
    public var downloadedBytes: Int64
    public var completedChunks: Int
    public var totalChunks: Int
    public var updatedAt: Date
    public var unavailableChannels: [String]
    public var hasCommittedArchive: Bool
    public var resumable: Bool { availability == .partial }
    public var canReplay: Bool { availability == .complete || hasCommittedArchive }

    public init(session: SessionSummary, availability: ReplayArchiveAvailability, downloadedBytes: Int64, completedChunks: Int, totalChunks: Int, updatedAt: Date, unavailableChannels: [String] = [], hasCommittedArchive: Bool = false) {
        self.session = session
        self.availability = availability
        self.downloadedBytes = downloadedBytes
        self.completedChunks = completedChunks
        self.totalChunks = totalChunks
        self.updatedAt = updatedAt
        self.unavailableChannels = unavailableChannels
        self.hasCommittedArchive = hasCommittedArchive
    }
}
