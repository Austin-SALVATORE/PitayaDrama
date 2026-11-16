import Foundation

/// 站源：核心 initialize 回的 sources（构建时内置的站源模块），只留可用的，顺序照核心给的。
/// 只有一个站源时（火龙果短剧只内置红果）界面不显示站源选择，与 1.0.0 一致。
struct SourceSite: Identifiable, Hashable, Sendable {
    static let defaultID = "hongguo"

    let id: String
    let name: String
    let description: String

    /// 解析核心的 sources：没有 id 或 available 为 false 的跳过，同一 id 只留第一个。
    static func list(fromCore rows: [Any]) -> [SourceSite] {
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let row = row as? [String: Any],
                  let id = row["id"] as? String, !id.isEmpty,
                  row["available"] as? Bool != false,
                  seen.insert(id).inserted
            else { return nil }
            let name = row["name"] as? String ?? ""
            return SourceSite(id: id, name: name.isEmpty ? id : name, description: row["description"] as? String ?? "")
        }
    }

    /// 选中的站源不在列表里时改选红果，列表里没有红果就选第一个；列表为空时不变。
    static func selection(_ current: String, among sites: [SourceSite]) -> String {
        guard !sites.contains(where: { $0.id == current }) else { return current }
        return sites.first { $0.id == defaultID }?.id ?? sites.first?.id ?? current
    }
}
