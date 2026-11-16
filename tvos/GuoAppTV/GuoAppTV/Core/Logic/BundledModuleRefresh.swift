import Foundation

/// 应用更新后让核心换上这一版内置的站源模块。
///
/// 核心的数据目录在 Caches，应用更新后还在；核心只从 modules/<标识> 加载模块，而且只在内置的版本号
/// 更高时才覆盖它（upstream/native/core/module_bundled.go）。同一版本号换了内容、或退回更低的版本时，
/// 跑的仍是之前装下的那份。构建脚本把 tvos/modules.lock.json 里的标识、标签和 sha256 写进 Info.plist 的
/// GUOAppBundledModules；它和上次启动记下的不同时，在 initialize 之前删掉这些标识的 modules/<标识>，
/// 核心启动时随即从内置副本重新安装。用户卸载过的内置模块（modules/.bundled-removed.json）和其它模块不动；
/// 模块自己存的状态在数据目录的 module-<标识>-* 文件里，不受影响。
enum BundledModuleRefresh {
    static let infoKey = "GUOAppBundledModules"
    static let stampName = "bundled-modules.stamp"

    /// 「标识@标签:sha:sha」用逗号隔开；取出其中合法的模块标识（与核心的 moduleIDPattern 一致）。
    static func moduleIDs(stamp: String) -> [String] {
        stamp.split(separator: ",").compactMap { entry in
            let id = String(entry.split(separator: "@", maxSplits: 1).first ?? "")
            return isModuleID(id) ? id : nil
        }
    }

    /// 需要时删掉内置模块的安装目录，返回删了哪些标识。stamp 为空（不是经构建脚本出的包）时什么都不做。
    /// 删除失败时抛错且不记新的 stamp，下次启动再试。
    @discardableResult
    static func apply(stamp: String, dataDirectory: URL, fileManager: FileManager = .default) throws -> [String] {
        guard !stamp.isEmpty else { return [] }
        let stampFile = dataDirectory.appendingPathComponent(stampName)
        if let previous = try? String(contentsOf: stampFile, encoding: .utf8), previous == stamp { return [] }
        let modules = dataDirectory.appendingPathComponent("modules", isDirectory: true)
        let removedByUser = (try? Data(contentsOf: modules.appendingPathComponent(".bundled-removed.json")))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        var removed: [String] = []
        for id in moduleIDs(stamp: stamp) where !removedByUser.contains(id) {
            let folder = modules.appendingPathComponent(id, isDirectory: true)
            guard fileManager.fileExists(atPath: folder.path) else { continue }
            try fileManager.removeItem(at: folder)
            removed.append(id)
        }
        try fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try Data(stamp.utf8).write(to: stampFile, options: .atomic)
        return removed
    }

    private static func isModuleID(_ id: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_-")
        guard let first = id.first, id.count <= 32, first != "_", first != "-" else { return false }
        return id.allSatisfy { allowed.contains($0) }
    }
}
