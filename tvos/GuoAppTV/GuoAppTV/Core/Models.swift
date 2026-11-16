import Foundation

// MARK: - 分集

/// 分集。核心返回的原始分集对象要在解析播放地址时原样回传（`resolve` 的
/// `chapter`），这里存成序列化后的 JSON `Data`：Episode 因此是纯值类型、
/// Sendable，可以安全地跨 `CoreClient` actor 传递（Swift 6 严格并发）。
struct Episode: Identifiable, Sendable {
    let id: String
    let title: String
    let number: Int
    let vip: Bool
    /// 原始分集 JSON（已补全 currentEpisode）。
    private let rawJSON: Data

    /// 分集序号（从 1 开始）；核心返回的 currentEpisode 为空时用列表位置兜底。
    init(raw: [String: Any], fallback: Int) {
        var copy = raw
        if intValue(copy, "currentEpisode") <= 0 {
            copy["currentEpisode"] = fallback
        }
        let number = max(intValue(copy, "currentEpisode"), 0)
        let rawId = stringValue(copy, "id")
        let rawTitle = stringValue(copy, "title")
        self.number = number
        id = rawId.isEmpty ? "ep-\(number)" : rawId
        title = rawTitle.isEmpty ? "第\(number)集" : rawTitle
        vip = copy["vip"] as? Bool == true
        // copy 来自核心 JSON 解析结果（只多了一个整数字段），正常总能重新序列化。
        // 先用 isValidJSONObject 把关：非法对象时 data(withJSONObject:) 抛的是
        // Objective-C 异常，try? 接不住，会直接崩溃。
        rawJSON = JSONSerialization.isValidJSONObject(copy)
            ? (try? JSONSerialization.data(withJSONObject: copy)) ?? Data("{}".utf8)
            : Data("{}".utf8)
    }

    /// 回传给核心的原始分集对象。
    func requestJSON() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: rawJSON)) as? [String: Any] ?? [:]
    }
}

// MARK: - 详情 / 目录 / 分类

struct DramaDetail {
    let drama: Drama
    let episodes: [Episode]
    let warning: String

    init(dict: [String: Any]) {
        drama = Drama(dict: dict["drama"] as? [String: Any] ?? [:])
        let rows = dict["chapters"] as? [Any] ?? []
        episodes = rows.enumerated().compactMap { index, row in
            guard let row = row as? [String: Any] else { return nil }
            return Episode(raw: row, fallback: index + 1)
        }
        warning = stringValue(dict, "warning")
    }
}

/// 出品方页的导航路由值：与 Drama 一样走值链接 + navigationDestination
/// 注册。不要用闭包目标链接跳出品方页——tvOS 16 上它会被父视图重绘
/// 重复触发，把出品方页再盖到目标页上面。
struct ProducerRoute: Hashable {
    let drama: Drama
}

struct ProducerWorks {
    let producer: String
    let items: [Drama]

    init(dict: [String: Any]) {
        producer = stringValue(dict, "producer")
        let rows = dict["items"] as? [Any] ?? []
        items = rows.compactMap { ($0 as? [String: Any]).map(Drama.init(dict:)) }
    }
}

struct CatalogPage {
    let items: [Drama]
    let hasMore: Bool
    let page: Int
    let warning: String
    let fresh: Bool

    init(dict: [String: Any]) {
        let rows = dict["items"] as? [Any] ?? []
        items = rows.compactMap { ($0 as? [String: Any]).map(Drama.init(dict:)) }
        hasMore = dict["hasMore"] as? Bool == true
        warning = stringValue(dict, "warning")
        let page = intValue(dict, "page")
        self.page = page > 0 ? page : 1
        fresh = dict["fresh"] as? Bool == true
    }
}

struct Category: Identifiable, Hashable {
    static let all = Category(id: "", name: "全部")
    let id: String
    let name: String

    init(dict: [String: Any]) {
        id = stringValue(dict, "id")
        let name = stringValue(dict, "name")
        self.name = name.isEmpty ? "全部" : name
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

// MARK: - 播放计划 / 弹幕

struct PlaybackPlan {
    let url: String
    let headers: [String: String]
    let quality: Int
    let qualities: [Int]
    let session: String
    let danmakuId: String
    let routeIndex: Int
    let routeCount: Int
    let local: Bool
    let expiresAt: Int
    let decryptionKey: String
    /// CENC 解密密钥（hex），红果等加密源才有；传给 mpv 的 decryption-key 选项。

    var hasAlternative: Bool { !session.isEmpty && routeIndex + 1 < routeCount }

    init(dict: [String: Any]) {
        url = stringValue(dict, "url")
        var headers: [String: String] = [:]
        for (key, value) in dict["headers"] as? [String: Any] ?? [:] {
            headers[key] = "\(value)"
        }
        self.headers = headers
        quality = intValue(dict, "quality")
        let qualities = (dict["qualities"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        self.qualities = Array(Set(qualities)).sorted(by: >)
        session = stringValue(dict, "session")
        danmakuId = stringValue(dict, "danmakuId")
        routeIndex = intValue(dict, "routeIndex")
        let routeCount = intValue(dict, "routeCount")
        self.routeCount = routeCount > 0 ? routeCount : 1
        local = dict["local"] as? Bool == true
        expiresAt = intValue(dict, "expiresAt")
        decryptionKey = stringValue(dict, "decryptionKey")
    }
}

struct DanmakuItem: Identifiable {
    let id: String
    let text: String
    let timeMs: Int
}

struct DanmakuPage {
    let episodeId: String
    let startMs: Int
    let nextMs: Int
    let items: [DanmakuItem]

    init(dict: [String: Any]) {
        episodeId = stringValue(dict, "episodeId")
        startMs = intValue(dict, "startMs")
        nextMs = intValue(dict, "nextMs")
        let rows = dict["items"] as? [Any] ?? []
        items = rows.prefix(90).compactMap { row in
            guard let row = row as? [String: Any] else { return nil }
            return DanmakuItem(
                id: stringValue(row, "id"),
                text: stringValue(row, "text"),
                timeMs: intValue(row, "timeMs")
            )
        }
    }
}

/// 榜单：与 Dart 侧 RankingBoard 对齐，Go 核心 `rankingBoards` 返回。
struct RankingBoard: Identifiable, Hashable {
    let id: String
    let source: String
    let name: String
    let description: String

    init(dict: [String: Any]) {
        id = stringValue(dict, "id")
        source = stringValue(dict, "source")
        name = stringValue(dict, "name")
        description = stringValue(dict, "description")
    }
}

/// 一页榜单：items 里每个元素是 `{rank, drama, metric}`，drama 与目录里的
/// Drama 同一结构；顺序即排名，rank 不单独存（界面按顺序展示）。
struct RankingPage {
    let items: [Drama]
    let page: Int
    let hasMore: Bool
    let warning: String

    init(dict: [String: Any]) {
        let rows = dict["items"] as? [Any] ?? []
        items = rows.compactMap { row in
            guard let row = row as? [String: Any],
                  let dramaDict = row["drama"] as? [String: Any]
            else { return nil }
            var drama = Drama(dict: dramaDict)
            drama.episodes = EpisodeCount.fromRanking(reported: drama.episodes, source: drama.source)
            return drama
        }
        let page = intValue(dict, "page")
        self.page = page > 0 ? page : 1
        hasMore = dict["hasMore"] as? Bool == true
        warning = stringValue(dict, "warning")
    }
}
