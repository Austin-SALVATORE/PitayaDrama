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

    /// 核心一个可用的站源都没有时给用户看的话。moduleRows 是核心 modules 动作回的 items，带出其中的错误。
    /// 核心只在进程启动时安装、加载模块，同一次运行里再 initialize 不会重新加载，所以要请用户重开应用。
    static func unavailableMessage(moduleRows: [Any]) -> String {
        let problems = moduleRows.compactMap { row -> String? in
            guard let row = row as? [String: Any],
                  let error = row["error"] as? String, !error.isEmpty
            else { return nil }
            let name = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? row["id"] as? String ?? ""
            return name.isEmpty ? error : "\(name)：\(error)"
        }
        let detail = problems.isEmpty ? "" : "（\(problems.joined(separator: "；"))）"
        return "站源模块没有加载成功\(detail)。请完全退出应用（连按两下 TV 键，把本应用向上滑走）后重新打开；"
            + "还不行再重新安装应用。"
    }

    /// 选中的站源不在列表里时改选红果，列表里没有红果就选第一个；列表为空时不变。
    static func selection(_ current: String, among sites: [SourceSite]) -> String {
        guard !sites.contains(where: { $0.id == current }) else { return current }
        return sites.first { $0.id == defaultID }?.id ?? sites.first?.id ?? current
    }
}
