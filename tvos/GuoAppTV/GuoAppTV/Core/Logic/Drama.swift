import Foundation

// 剧（Drama）和解析核心 JSON 的容错小工具放在 Logic 里：追剧与观看进度存盘（tv-state.json）的
// 读写要在 Mac 上单测（StateFile），Models.swift 里其它核心回复的解析也用同一组工具。

// MARK: - 容错解析

func stringValue(_ dict: [String: Any], _ key: String) -> String {
    dict[key] as? String ?? ""
}

func intValue(_ dict: [String: Any], _ key: String) -> Int {
    if let number = dict[key] as? NSNumber { return number.intValue }
    if let text = dict[key] as? String, let number = Int(text) { return number }
    return 0
}

func stringList(_ dict: [String: Any], _ key: String) -> [String] {
    (dict[key] as? [Any] ?? []).compactMap { $0 as? String }
}

// MARK: - 剧

struct Drama: Identifiable, Hashable, Codable {
    var id: String
    var source: String
    var sourceId: String
    var title: String
    var description: String
    var cover: String
    var episodes: Int
    var category: String
    var vip: Bool?
    var heat: String
    var views: String
    var onlineDate: String
    /// 出品方（只有带出品方数据的核心才有；1.0.0 存下的剧没有这个字段，必须可选，否则追剧与进度整份读不出来）。
    var producer: String?
    var tags: [String]
    var releaseStatus: String
    /// 评分（核心的 metadata 补全；旧版存下的剧没有这个字段，可选）。
    var score: String?

    var releaseLabel: String {
        switch releaseStatus {
        case "finished", "completed": return "已完结"
        case "ongoing": return "连载中"
        default: return ""
        }
    }

    init(dict: [String: Any]) {
        id = stringValue(dict, "id")
        source = stringValue(dict, "source").isEmpty ? "hongguo" : stringValue(dict, "source")
        sourceId = stringValue(dict, "sourceId")
        title = stringValue(dict, "title").isEmpty ? "短剧" : stringValue(dict, "title")
        description = stringValue(dict, "description")
        cover = stringValue(dict, "cover")
        episodes = intValue(dict, "episodes")
        category = stringValue(dict, "category")
        vip = dict["vip"] as? Bool
        heat = dict["heat"].map { "\($0)" } ?? ""
        views = dict["views"].map { "\($0)" } ?? ""
        onlineDate = stringValue(dict, "onlineDate")
        let producerText = stringValue(dict, "producer")
        producer = producerText.isEmpty ? nil : producerText
        tags = stringList(dict, "tags")
        releaseStatus = stringValue(dict, "releaseStatus")
        let scoreText = stringValue(dict, "score")
        score = scoreText.isEmpty ? nil : scoreText
    }

    /// 发给 Go 核心的 drama 结构，与 Dart 侧 Drama.toJson 对齐。
    func requestJSON() -> [String: Any] {
        var json: [String: Any] = [
            "metadataSchema": 1,
            "id": id,
            "source": source,
            "sourceId": sourceId,
            "title": title,
            "description": description,
            "cover": cover,
            "episodes": episodes,
            "category": category,
            "heat": heat,
            "views": views,
            "onlineDate": onlineDate,
            "tags": tags,
            "releaseStatus": releaseStatus,
        ]
        if let vip { json["vip"] = vip }
        if let score { json["score"] = score }
        if let producer { json["producer"] = producer }
        return json
    }
}
