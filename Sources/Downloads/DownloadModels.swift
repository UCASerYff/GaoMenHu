import Foundation

public enum DownloadState: String, Codable, CaseIterable, Sendable {
    case awaitingReview, queued, running, pausing, paused, waitingForNetwork, waitingForDestination, retryScheduled, verifying, committing, completed, partial, failed, cancelled
    public var title: String { switch self {
    case .awaitingReview: return "待复核"; case .queued: return "排队中"; case .running: return "下载中"; case .pausing: return "正在暂停"; case .paused: return "已暂停"; case .waitingForNetwork: return "等待网络"; case .waitingForDestination: return "等待目标目录"; case .retryScheduled: return "等待重试"; case .verifying: return "校验中"; case .committing: return "正在发布文件"; case .completed: return "已完成"; case .partial: return "部分完成"; case .failed: return "失败"; case .cancelled: return "已取消"
    } }
    public var isTerminal: Bool { [.completed,.partial,.failed,.cancelled].contains(self) }
    public var isActive: Bool { [.running,.pausing,.verifying,.committing].contains(self) }
    public var canResume: Bool { [.paused,.waitingForNetwork,.waitingForDestination,.retryScheduled,.failed,.partial,.cancelled].contains(self) }
}
public struct PublishedArtifact: Codable, Equatable, Sendable {
    public var fileName: String
    public var byteCount: Int64
    public var sha256: String
    public var device: UInt64 = 0
    public var inode: UInt64 = 0
}
public struct DownloadJob: Codable, Identifiable, Sendable {
    public var id: UUID
    public var requestID: UUID?
    public var itemIDs: [UUID]
    public var createdAt: Date
}
public struct DestinationGrant: Codable, Identifiable, Sendable {
    public var id: UUID
    public var displayPath: String
    public var bookmark: Data
    public var device: UInt64
    public var inode: UInt64
    public var volumeUUID: String?
    // Imported grants are evidence of the old selection, not an authorization
    // transferred to this host. Cleared only after selecting the same directory.
    public var requiresReauthorization: Bool? = nil
}
public struct DownloadSettings: Codable, Equatable, Sendable {
    public var concurrency: Int = 2
    public var speedLimitBytesPerSecond: Int64 = 0
    public var maxItemBytes: Int64 = 20 * 1024 * 1024 * 1024
    public var maxStagingBytes: Int64 = 40 * 1024 * 1024 * 1024
    public var appearance: String = "system"
    public init() {}
}
public struct DownloadItem: Codable, Identifiable, Sendable {
    public var id: UUID
    public var jobID: UUID
    public var destinationID: UUID
    public var state: DownloadState
    public var sourceURL: String
    public var sourceFingerprint: String
    public var displayURL: String
    public var suggestedName: String
    public var bytesReceived: Int64
    public var expectedBytes: Int64?
    public var bytesPerSecond: Double
    public var sha256: String?
    public var errorMessage: String?
    public var errorCategory: String? = nil
    public var retryAt: Date?
    public var artifact: PublishedArtifact?
    public var createdAt: Date
    public var etag: String?
    public var lastModified: String?
    public var attempts: Int = 0
    public var resumeExplanation: String?
    public var stagingName: String
    public var stagingDevice: UInt64?
    public var stagingInode: UInt64?
    public var pendingArtifact: PublishedArtifact?
    public var partialSHA256: String?
}
struct DownloadDatabase: Codable {
    var schemaVersion = 1
    var revision: UInt64 = 0
    var installationID: UUID
    var migrationHistory: [String] = ["v1: 初始事务格式"]
    var items: [DownloadItem] = []
    var jobs: [DownloadJob] = []
    var destinations: [DestinationGrant] = []
    var settings = DownloadSettings()
}
enum DownloadError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
func downloadDigest(_ data: Data) -> String { importDigest(data) }
