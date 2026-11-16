import Testing
@testable import GuoAppLogic

/// initialize 回的 sources（模块核心 5424fb6 起没有 allSources 了）。
struct SourceSiteTests {
    /// 模块核心实测的一条（host 探针，内置红果模块 v1.0.2）。
    private let hongguoRow: [String: Any] = [
        "id": "hongguo", "name": "红果", "description": "短剧 · 漫剧 · AI 剧 · 听书", "available": true,
        "group": "", "groupName": "", "entryName": "", "search": true, "suggestions": true,
        "recommendations": true, "danmaku": true, "devices": true, "account": false, "metadata": true,
        "adult": false, "vipPrompt": true,
    ]

    /// 只内置红果：一个站源、名字照核心给的，界面因此不显示站源选择（与 1.0.0 的火龙果短剧一样）。
    @Test func hongguoOnlyBuildHasOneSource() {
        let sites = SourceSite.list(fromCore: [hongguoRow])
        #expect(sites == [SourceSite(id: "hongguo", name: "红果", description: "短剧 · 漫剧 · AI 剧 · 听书")])
        #expect(SourceSite.selection("hongguo", among: sites) == "hongguo")
    }

    @Test func skipsUnavailableMalformedAndDuplicateRows() {
        let rows: [Any] = [
            hongguoRow,
            ["id": "sorani", "name": "青空", "available": false],
            ["name": "没有标识"],
            "not an object",
            ["id": "hongguo", "name": "重复"],
            ["id": "guipian"],
        ]
        let sites = SourceSite.list(fromCore: rows)
        #expect(sites.map(\.id) == ["hongguo", "guipian"])
        #expect(sites.last?.name == "guipian")
    }

    @Test func missingSourceListIsEmpty() {
        #expect(SourceSite.list(fromCore: []).isEmpty)
    }

    /// 选中的站源不在了：回到红果；没有红果时选第一个；没有任何站源时不动。
    @Test func selectionFallsBackToHongguoThenFirst() {
        let hongguo = SourceSite(id: "hongguo", name: "红果", description: "")
        let guipian = SourceSite(id: "guipian", name: "鬼片", description: "")
        #expect(SourceSite.selection("guipian", among: [hongguo, guipian]) == "guipian")
        #expect(SourceSite.selection("sorani", among: [guipian, hongguo]) == "hongguo")
        #expect(SourceSite.selection("sorani", among: [guipian]) == "guipian")
        #expect(SourceSite.selection("sorani", among: []) == "sorani")
    }
}
