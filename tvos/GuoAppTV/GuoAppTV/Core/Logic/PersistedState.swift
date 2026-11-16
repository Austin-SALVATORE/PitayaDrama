import Foundation

// MARK: - 追剧 / 观看进度的存盘格式（Caches/tv-state.json）

struct WatchProgress: Codable, Equatable {
    var drama: Drama
    var episode: Int
    var episodeTitle: String
    var position: Double
    var duration: Double
    var updatedAt: Date

    var episodeKey: String { "\(drama.id)#\(episode)" }
}

struct FollowedDrama: Codable, Equatable {
    var drama: Drama
    var followedAt: Date
    /// 追剧更新（FollowUpdate）：用户已知的集数；nil 表示还没有基准（第一次检查时设）。
    /// 以下三个字段都是可选的：第四阶段之前存下的追剧照样能读出来。
    var knownEpisodes: Int?
    /// 最近一次检查（核心 followCheck）看到的集数。
    var latestEpisodes: Int?
    var checkedAt: Date?
}

struct PersistedState: Codable, Equatable {
    var follows: [FollowedDrama] = []
    var progress: [WatchProgress] = []
}

// MARK: - 读写

/// tv-state.json 的读写。文件在却读不出来（格式变了、写坏了）时不能让下一次保存把它盖掉：
/// 先挪到旁边改名 tv-state.unreadable-<时间>.json（最多留 keptUnreadableCopies 份），这次从空的开始。
/// 挪不动时这次启动不能保存（Store 据此停止写盘）。文件不存在是正常情况（新装、Caches 被系统清掉）。
struct StateFile {
    static let keptUnreadableCopies = 3

    enum Loaded: Equatable {
        case state(PersistedState)
        case missing
        /// movedTo：挪到了哪里；nil 表示没挪动，原文件还在原处。
        case unreadable(reason: String, movedTo: URL?)
    }

    let url: URL

    func load(now: Date = Date(), fileManager: FileManager = .default) -> Loaded {
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            return .state(try JSONDecoder().decode(PersistedState.self, from: data))
        } catch {
            let reason = String(String(describing: error).prefix(300))
            return .unreadable(reason: reason, movedTo: moveAside(now: now, fileManager: fileManager))
        }
    }

    func save(_ state: PersistedState) throws {
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    /// 已挪到旁边的读不出来的旧文件，按时间从旧到新。
    func unreadableCopies(fileManager: FileManager = .default) -> [URL] {
        let directory = url.deletingLastPathComponent()
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix(unreadablePrefix) && $0.hasSuffix(".json") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    private var unreadablePrefix: String { url.deletingPathExtension().lastPathComponent + ".unreadable-" }

    private func moveAside(now: Date, fileManager: FileManager) -> URL? {
        let directory = url.deletingLastPathComponent()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = formatter.string(from: now)
        var target = directory.appendingPathComponent("\(unreadablePrefix)\(stamp).json")
        var attempt = 1
        while fileManager.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("\(unreadablePrefix)\(stamp)-\(attempt).json")
            attempt += 1
        }
        do {
            try fileManager.moveItem(at: url, to: target)
        } catch {
            return nil
        }
        for old in unreadableCopies(fileManager: fileManager).dropLast(Self.keptUnreadableCopies) {
            try? fileManager.removeItem(at: old)
        }
        return target
    }
}
