import Testing
@testable import GuoAppLogic

struct GatewayRevivalTests {
    @Test func readsTheCoreAnswer() {
        #expect(GatewayRevival(coreValue: "idle") == .idle)
        #expect(GatewayRevival(coreValue: "alive") == .alive)
        #expect(GatewayRevival(coreValue: "revived") == .revived)
        #expect(GatewayRevival(coreValue: "reset") == .reset)
    }

    /// 不认识的回答（核心没带这个补丁、返回了别的）按「还在」处理：不能因此反复重新起播。
    @Test func unknownAnswerCountsAsAlive() {
        #expect(GatewayRevival(coreValue: "") == .alive)
        #expect(GatewayRevival(coreValue: "something else") == .alive)
    }

    @Test func onlyRevivedAndResetMeanTheServiceWasLost() {
        #expect(GatewayRevival.revived.wasLost)
        #expect(GatewayRevival.reset.wasLost)
        #expect(!GatewayRevival.alive.wasLost)
        #expect(!GatewayRevival.idle.wasLost)
    }

    /// 起播时记下代数；之后服务丢过一次，代数就变了——播放器这时报失败要重新起播，而不是报「播放失败」。
    @Test func generationAdvancesEachTimeTheServiceIsLost() {
        let start = GatewayGeneration()
        #expect(start.after(.alive) == start)
        #expect(start.after(.idle) == start)
        let lostOnce = start.after(.revived)
        #expect(lostOnce != start)
        #expect(lostOnce.after(.alive) == lostOnce)
        #expect(lostOnce.after(.reset) != lostOnce)
        #expect(lostOnce.after(.reset) != start)
    }
}

struct GatewayRecoveryTests {
    private let gateway = "http://127.0.0.1:51234/token/asset.m3u8"

    /// 地址是在服务丢失之前拿到的：这次失败算在服务头上，重新起播。
    @Test func restartsWhenTheServiceWasLostAfterTheAddressWasIssued() {
        let before = GatewayGeneration()
        #expect(GatewayRecovery.shouldRestart(planURL: gateway, planGeneration: before, current: before.after(.revived)))
        #expect(GatewayRecovery.shouldRestart(planURL: gateway, planGeneration: before, current: before.after(.reset)))
    }

    /// 服务一直在：是片源或线路的问题，照常换线路 / 报播放失败。
    @Test func doesNotRestartWhenTheServiceWasNeverLost() {
        let generation = GatewayGeneration().after(.revived)
        #expect(!GatewayRecovery.shouldRestart(planURL: gateway, planGeneration: generation, current: generation))
    }

    /// 不经本机播放服务的地址（直连、本地文件）失败与它无关，不白白重新解析一次。
    @Test func doesNotRestartForAddressesOutsideTheLocalService() {
        let before = GatewayGeneration()
        let after = before.after(.reset)
        #expect(!GatewayRecovery.shouldRestart(planURL: "https://cdn.example.com/a.m3u8", planGeneration: before, current: after))
        #expect(!GatewayRecovery.shouldRestart(planURL: "file:///tmp/a.mp4", planGeneration: before, current: after))
    }

    /// 从本集最后真正播到的位置接着播；播放器失败后进度会被清零，不能拿那时的进度。
    @Test func restartsFromTheLastPlayedPosition() {
        #expect(GatewayRecovery.restartPosition(lastPlayed: 312.5, startPosition: 40) == 312.5)
    }

    /// 还没播出画面就失败：用原来的起播位置（续播点）。
    @Test func restartsFromTheStartPositionWhenNothingPlayedYet() {
        #expect(GatewayRecovery.restartPosition(lastPlayed: 0, startPosition: 40) == 40)
    }
}
