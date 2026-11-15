import Foundation
import Darwin

enum Store {
    static let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Reprise", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let videosFile = appSupportDir.appendingPathComponent("videos.json")
    static let logFile = appSupportDir.appendingPathComponent("premieres.log")
    static let lockFile = appSupportDir.appendingPathComponent("encore.lock")
    static let settingsFile = appSupportDir.appendingPathComponent("settings.json")
    static let channelsFile = appSupportDir.appendingPathComponent("channels.json")
    static let discoveredFile = appSupportDir.appendingPathComponent("discovered.json")

    private static var lockFileDescriptor: Int32 = -1

    /// Tries to acquire an exclusive lock so two instances can never overwrite each other's
    /// videos.json at the same time. Returns false if an instance is already running.
    static func acquireSingleInstanceLock() -> Bool {
        let fd = open(lockFile.path, O_CREAT | O_WRONLY, 0o644)
        guard fd >= 0 else { return true } // couldn't create the lock file: just run anyway
        let result = flock(fd, LOCK_EX | LOCK_NB)
        if result != 0 {
            close(fd)
            return false
        }
        lockFileDescriptor = fd
        return true
    }

    static let videosBackup = appSupportDir.appendingPathComponent("videos.json.backup")
    private(set) static var loadFailed = false
    private(set) static var loadedBackup = false

    private static func decodeVideos(_ data: Data) throws -> [MonitoredVideo] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([MonitoredVideo].self, from: data)
    }

    private static func readIfPresent(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }

    static func load() -> [MonitoredVideo] {
        loadFailed = false
        loadedBackup = false
        do {
            if let data = try readIfPresent(videosFile) {
                return try decodeVideos(data)
            }
            guard try readIfPresent(videosBackup) != nil else { return [] }
        } catch {
            appendLog("[Store] Could not read videos.json: \(error.localizedDescription)")
        }

        loadFailed = true
        if let data = try? Data(contentsOf: videosBackup), let videos = try? decodeVideos(data) {
            loadedBackup = true
            return videos
        }
        return []
    }

    static func save(_ videos: [MonitoredVideo], restoringBackup: Bool = false) throws {
        guard !loadFailed || (loadedBackup && restoringBackup) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(videos)

        if let previous = try readIfPresent(videosFile) {
            if restoringBackup {
                let preserved = appSupportDir.appendingPathComponent("videos.json.replaced-\(UUID().uuidString)")
                try previous.write(to: preserved, options: .atomic)
            } else {
                // Only known-good data can replace the recovery copy.
                _ = try decodeVideos(previous)
                if previous != data {
                    try previous.write(to: videosBackup, options: .atomic)
                }
            }
        } else if try readIfPresent(videosBackup) == nil {
            try data.write(to: videosBackup, options: .atomic)
        }
        try data.write(to: videosFile, options: .atomic)
        loadFailed = false
        loadedBackup = false
    }

    static func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsFile) else { return AppSettings() }
        guard let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            appendLog("[Store] ⚠️ Could not read settings.json — using default settings.")
            return AppSettings()
        }
        return settings
    }

    static func saveSettings(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: settingsFile, options: .atomic)
    }

    static func loadChannels() -> [TrackedChannel] {
        guard let data = try? Data(contentsOf: channelsFile) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TrackedChannel].self, from: data)) ?? []
    }

    static func saveChannels(_ channels: [TrackedChannel]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(channels) else { return }
        try? data.write(to: channelsFile, options: .atomic)
    }

    static func loadDiscovered() -> [DiscoveredVideo] {
        guard let data = try? Data(contentsOf: discoveredFile) else { return [] }
        return (try? JSONDecoder().decode([DiscoveredVideo].self, from: data)) ?? []
    }

    static func saveDiscovered(_ discovered: [DiscoveredVideo]) {
        guard let data = try? JSONEncoder().encode(discovered) else { return }
        try? data.write(to: discoveredFile, options: .atomic)
    }

    /// Generous for a text log fed by 30-second-interval checks — this caps premieres.log
    /// from growing forever, which it did unconditionally before. One rotated backup
    /// (premieres.log.old) is kept, so at most ~2x this much ever sits on disk.
    private static let maxLogFileBytes = 5_000_000

    private static func rotateLogIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: logFile.path))?[.size] as? Int,
              size > maxLogFileBytes else { return }
        let oldLog = logFile.deletingLastPathComponent().appendingPathComponent("premieres.log.old")
        try? FileManager.default.removeItem(at: oldLog)
        try? FileManager.default.moveItem(at: logFile, to: oldLog)
    }

    static func appendLog(_ line: String) {
        rotateLogIfNeeded()
        let entry = line + "\n"
        guard let entryData = entry.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: entryData)
            }
        } else {
            try? entry.write(to: logFile, atomically: true, encoding: .utf8)
        }
    }
}
