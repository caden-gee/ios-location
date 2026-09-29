import SwiftUI

/// 虚拟定位的运行状态
/// 用 enum 收敛状态,SwiftUI 中用 switch 强制穷举,避免状态不一致
enum SpoofingState: Equatable {
    /// 未开启
    case off
    /// 正在生效中(用户已点设定/关闭,但还没完成"重启定位服务")
    case pending(name: String, isClosing: Bool)
    /// 已开启
    case on(name: String)
    /// 操作失败(具体错误原因)
    case failed(reason: String)

    /// 状态卡主文案
    var primaryText: String {
        switch self {
        case .off:
            return "Not spoofing"
        case .pending(_, let isClosing):
            return isClosing ? "Turning off…" : "Activating…"
        case .on(let name):
            return name
        case .failed:
            return "Couldn't change location"
        }
    }

    /// 状态卡副文案(可选)
    var subText: String? {
        switch self {
        case .off:
            return "Search or tap the map to pick a location"
        case .pending:
            return "Restart Location Services to finish"
        case .on:
            return "Your location is being spoofed"
        case .failed(let reason):
            return reason
        }
    }

    /// 状态卡图标
    var symbolName: String {
        switch self {
        case .off:      return "location.slash"
        case .pending:  return "hourglass"
        case .on:       return "location.fill"
        case .failed:   return "exclamationmark.triangle.fill"
        }
    }

    /// 状态卡图标颜色
    var tint: Color {
        switch self {
        case .off:      return .secondary
        case .pending:  return .orange
        case .on:       return .accentColor
        case .failed:   return .red
        }
    }
}
