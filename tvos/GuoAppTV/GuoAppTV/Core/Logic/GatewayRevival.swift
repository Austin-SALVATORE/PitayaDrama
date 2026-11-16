import Foundation

/// 核心检查本机播放服务后的结论（核心补丁 ReviveNativeStream 的返回值，
/// 见 fork/core/tvos_stream_revive.go）。
enum GatewayRevival: String, Sendable {
    /// 核心还没就绪，或还没起过播（没有本机播放服务）。
    case idle
    /// 还在监听。
    case alive
    /// 监听没了，已在原端口恢复：播放地址不变。
    case revived
    /// 原端口拿不回来，旧服务已丢弃：旧播放地址作废，下次起播重新创建。
    case reset

    /// 不认识的回答按「还在」处理，免得因此反复重新起播。
    init(coreValue: String) {
        self = GatewayRevival(rawValue: coreValue) ?? .alive
    }

    /// 这次检查发现服务刚才不在了。
    var wasLost: Bool { self == .revived || self == .reset }
}

/// 本机播放服务是「第几代」：每丢失一次加一。起播时记下当时的代数；播放器报失败时代数变了，
/// 就是服务被系统回收（App 挂起）造成的——从刚才的位置重新起播，不当成播放失败。
struct GatewayGeneration: Equatable, Sendable {
    private(set) var value = 0

    func after(_ revival: GatewayRevival) -> GatewayGeneration {
        guard revival.wasLost else { return self }
        var next = self
        next.value += 1
        return next
    }
}

/// 播放器报失败时，判断是不是本机播放服务丢失造成的，以及从哪里重新起播。
enum GatewayRecovery {
    /// 地址经过本机播放服务、且拿到地址之后服务丢过：这次失败算在服务头上，重新起播而不是换线路 / 报错。
    /// planGeneration 要在向核心要地址之前记下——核心可能正好在服务丢失前后发出地址，
    /// 记早了最多白白重新起播一次，记晚了会把一个作废的地址当成新的。
    static func shouldRestart(planURL: String, planGeneration: GatewayGeneration, current: GatewayGeneration) -> Bool {
        GatewayEndpoint(planURL: planURL) != nil && planGeneration != current
    }

    /// 重新起播的位置：本集最后真正播到的位置；还没播出画面就用原来的起播位置。
    /// 不能用播放器当时的进度——失败后它会被清零。
    static func restartPosition(lastPlayed: Double, startPosition: Double) -> Double {
        lastPlayed > 0 ? lastPlayed : startPosition
    }
}
