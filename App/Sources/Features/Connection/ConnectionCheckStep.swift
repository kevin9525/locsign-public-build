import Foundation

enum ConnectionCheckStep: String, CaseIterable, Identifiable {
    case address, reachability, pairingFile, authentication, fileService, installationService

    var id: String { rawValue }
    var title: String {
        switch self {
        case .address: return "设备地址"
        case .reachability: return "设备服务响应"
        case .pairingFile: return "配对文件"
        case .authentication: return "设备连接与配对认证"
        case .fileService: return "文件传输服务连接"
        case .installationService: return "安装服务连接"
        }
    }

    var guidance: String {
        switch self {
        case .address: return "请填写设备 IP 地址；LocalDevVPN 通常为 10.7.0.1，不要填写网址。"
        case .reachability: return "请核对地址，保持手机解锁和 LocalDevVPN 开启，并检查 LocSign 的本地网络权限。连接失败本身不能确定是哪一项未就绪。"
        case .pairingFile: return "请导入这台手机的配对 plist。若保存的文件无法读取，先解锁手机；仍失败时重新导入。"
        case .authentication: return "请保持手机解锁并核对 VPN、地址和配对文件是否属于这台手机。网络恢复后仍无法认证，再重新生成并导入配对文件。"
        case .fileService, .installationService: return "请保持手机解锁、VPN 开启后重新检查。若服务仍不可用，可在诊断日志中查看失败阶段和错误。"
        }
    }

    init(_ stage: PairedProbeStage) {
        switch stage {
        case .pairingFile: self = .pairingFile
        case .authentication: self = .authentication
        case .fileService: self = .fileService
        case .installationService: self = .installationService
        }
    }
}

enum ConnectionCheckState: Equatable {
    case pending, checking, passed, failed, skipped, cancelled

    var title: String {
        switch self {
        case .pending: return "待检查"
        case .checking: return "检查中"
        case .passed: return "通过"
        case .failed: return "未通过"
        case .skipped: return "未执行"
        case .cancelled: return "已取消"
        }
    }
    var icon: String {
        switch self {
        case .pending: return "circle"
        case .checking: return "hourglass"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .skipped: return "minus.circle"
        case .cancelled: return "xmark.circle"
        }
    }
}
