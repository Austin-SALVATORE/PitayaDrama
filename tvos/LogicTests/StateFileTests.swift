import Foundation
import Testing
@testable import GuoAppLogic

/// tv-state.json：旧版存下的能读出来；读不出来的不能被下一次保存盖掉。
struct StateFileTests {
    /// 1.0.0 写出的样子（手写的假数据）：剧没有 producer，追剧没有 knownEpisodes / latestEpisodes / checkedAt，
    /// 日期是 JSONEncoder 默认的「自 2001-01-01 起的秒数」。
    private let sample100 = """
    {
      "follows": [
        {
          "drama": {
            "id": "hongguo:1000000000000000001", "source": "hongguo", "sourceId": "1000000000000000001",
            "title": "示例剧", "description": "", "cover": "", "episodes": 60, "category": "都市",
            "heat": "", "views": "", "onlineDate": "", "tags": ["都市"], "releaseStatus": "ongoing"
          },
          "followedAt": 784000000
        }
      ],
      "progress": [
        {
          "drama": {
            "id": "hongguo:1000000000000000002", "source": "hongguo", "sourceId": "1000000000000000002",
            "title": "另一部示例剧", "description": "简介", "cover": "", "episodes": 80, "category": "",
            "heat": "1.2万", "views": "", "onlineDate": "2026-10", "tags": [], "releaseStatus": "finished",
            "vip": false, "score": "9.1"
          },
          "episode": 3,
          "episodeTitle": "第3集",
          "position": 42.5,
          "duration": 95,
          "updatedAt": 784000100
        }
      ]
    }
    """

    private func scratchFile() throws -> (StateFile, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StateFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (StateFile(url: directory.appendingPathComponent("tv-state.json")), directory)
    }

    @Test func reads100State() throws {
        let (file, directory) = try scratchFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(sample100.utf8).write(to: file.url)

        guard case .state(let state) = file.load() else {
            Issue.record("1.0.0 state should load")
            return
        }
        #expect(state.follows.count == 1)
        #expect(state.follows[0].drama.title == "示例剧")
        #expect(state.follows[0].drama.producer == nil)
        #expect(state.follows[0].knownEpisodes == nil)
        #expect(state.follows[0].checkedAt == nil)
        #expect(state.follows[0].followedAt == Date(timeIntervalSinceReferenceDate: 784_000_000))
        #expect(state.progress.count == 1)
        #expect(state.progress[0].episodeKey == "hongguo:1000000000000000002#3")
        #expect(state.progress[0].position == 42.5)
        #expect(state.progress[0].drama.score == "9.1")
        #expect(state.progress[0].drama.vip == false)
    }

    @Test func missingFileIsQuiet() throws {
        let (file, directory) = try scratchFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(file.load() == .missing)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    /// 格式对不上（如 1.1.0 合入时多出必填字段那种情况）：挪到旁边留着，之后的保存写新文件、不碰它。
    @Test func unreadableFileIsMovedAsideAndNeverOverwritten() throws {
        let (file, directory) = try scratchFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data(#"{"follows": 5}"#.utf8)
        try original.write(to: file.url)
        let now = Date(timeIntervalSince1970: 1_794_800_000)

        guard case .unreadable(_, let movedTo?) = file.load(now: now) else {
            Issue.record("an unreadable file should be moved aside")
            return
        }
        #expect(movedTo.lastPathComponent.hasPrefix("tv-state.unreadable-"))
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        #expect(try Data(contentsOf: movedTo) == original)

        let fresh = PersistedState(follows: [], progress: [])
        try file.save(fresh)
        #expect(file.load() == .state(fresh))
        #expect(try Data(contentsOf: movedTo) == original)
        #expect(file.unreadableCopies() == [movedTo])
    }

    @Test func keepsOnlyTheNewestUnreadableCopies() throws {
        let (file, directory) = try scratchFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        for minute in 0..<StateFile.keptUnreadableCopies {
            try Data("old \(minute)".utf8).write(
                to: directory.appendingPathComponent("tv-state.unreadable-20261101-12\(minute)000-000.json")
            )
        }
        try Data("not json".utf8).write(to: file.url)

        guard case .unreadable(_, let movedTo?) = file.load(now: Date(timeIntervalSince1970: 1_794_800_000)) else {
            Issue.record("an unreadable file should be moved aside")
            return
        }
        let kept = file.unreadableCopies().map(\.lastPathComponent)
        #expect(kept.count == StateFile.keptUnreadableCopies)
        #expect(!kept.contains("tv-state.unreadable-20261101-120000-000.json"))
        #expect(kept.last == movedTo.lastPathComponent)
    }

    @Test func savedStateReadsBack() throws {
        let (file, directory) = try scratchFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let drama = Drama(dict: ["id": "hongguo:9", "title": "示例", "episodes": 12])
        let state = PersistedState(
            follows: [FollowedDrama(drama: drama, followedAt: Date(timeIntervalSinceReferenceDate: 1), knownEpisodes: 12)],
            progress: []
        )
        try file.save(state)
        #expect(file.load() == .state(state))
    }
}
