import Foundation
import Testing
@testable import GuoAppLogic

/// 应用更新后，核心要换上这一版内置的站源模块（锁文件里的那份），而不是 Caches 里旧装的。
struct BundledModuleRefreshTests {
    private let stamp = "hongguo@v1.0.2:c91b038ac4f1e013:8b05f083fbf0d941"

    private func dataDirectory(installing ids: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundledModuleRefreshTests-\(UUID().uuidString)", isDirectory: true)
        for id in ids {
            let folder = directory.appendingPathComponent("modules/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: folder.appendingPathComponent("manifest.json"))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func installed(_ directory: URL, _ id: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("modules/\(id)").path)
    }

    @Test func readsModuleIDsFromTheStamp() {
        #expect(BundledModuleRefresh.moduleIDs(stamp: stamp) == ["hongguo"])
        #expect(BundledModuleRefresh.moduleIDs(stamp: "a@v1:x:y,b_2@v2:x:y") == ["a", "b_2"])
        #expect(BundledModuleRefresh.moduleIDs(stamp: "../x@v1:a:b,Upper@v1:a:b,-x@v1:a:b") == [])
        #expect(BundledModuleRefresh.moduleIDs(stamp: "") == [])
    }

    /// 第一次带 stamp 启动（如从 1.1.0 更新上来）：删掉旧装的内置模块，记下 stamp；其它模块不动。
    @Test func firstLaunchWithAStampReinstallsBundledModules() throws {
        let directory = try dataDirectory(installing: ["hongguo", "other"])
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try BundledModuleRefresh.apply(stamp: stamp, dataDirectory: directory) == ["hongguo"])
        #expect(!installed(directory, "hongguo"))
        #expect(installed(directory, "other"))
        let saved = try String(contentsOf: directory.appendingPathComponent(BundledModuleRefresh.stampName), encoding: .utf8)
        #expect(saved == stamp)
    }

    /// 同一个包再次启动：不动核心装好的模块。
    @Test func sameBuildLeavesTheInstalledModuleAlone() throws {
        let directory = try dataDirectory(installing: ["hongguo"])
        defer { try? FileManager.default.removeItem(at: directory) }
        try BundledModuleRefresh.apply(stamp: stamp, dataDirectory: directory)
        let folder = directory.appendingPathComponent("modules/hongguo", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(try BundledModuleRefresh.apply(stamp: stamp, dataDirectory: directory) == [])
        #expect(installed(directory, "hongguo"))
    }

    /// 锁文件变了（同版本号换内容、或退回旧版本）：再删一次，核心从内置副本重装。
    @Test func changedLockReinstallsAgain() throws {
        let directory = try dataDirectory(installing: ["hongguo"])
        defer { try? FileManager.default.removeItem(at: directory) }
        try BundledModuleRefresh.apply(stamp: stamp, dataDirectory: directory)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("modules/hongguo", isDirectory: true), withIntermediateDirectories: true
        )
        let rollback = "hongguo@v1.0.1:0000000000000000:1111111111111111"
        #expect(try BundledModuleRefresh.apply(stamp: rollback, dataDirectory: directory) == ["hongguo"])
        #expect(!installed(directory, "hongguo"))
    }

    /// 用户卸载过又自己装回的内置模块：核心不会再自动装它，所以也不删；.bundled-removed.json 不动。
    @Test func modulesRemovedByTheUserAreLeftAlone() throws {
        let directory = try dataDirectory(installing: ["hongguo"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let removedList = directory.appendingPathComponent("modules/.bundled-removed.json")
        try Data(#"["hongguo"]"#.utf8).write(to: removedList)
        #expect(try BundledModuleRefresh.apply(stamp: stamp, dataDirectory: directory) == [])
        #expect(installed(directory, "hongguo"))
        #expect(try Data(contentsOf: removedList) == Data(#"["hongguo"]"#.utf8))
    }

    /// 不是经构建脚本出的包（Info.plist 里没有 stamp）：不知道内置了什么，什么都不做。
    @Test func noStampDoesNothing() throws {
        let directory = try dataDirectory(installing: ["hongguo"])
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try BundledModuleRefresh.apply(stamp: "", dataDirectory: directory) == [])
        #expect(installed(directory, "hongguo"))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(BundledModuleRefresh.stampName).path))
    }
}
