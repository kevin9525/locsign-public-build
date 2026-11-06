import Foundation

enum LocSignError: LocalizedError {
    case signing(String), provisioning(String), install(String), infra(String)
    var errorDescription: String? {
        switch self {
        case .signing(let r): return "签名失败：\(r)"
        case .provisioning(let r): return "证书服务失败：\(r)"
        case .install(let r): return "安装失败：\(r)"
        case .infra(let r): return "内部错误：\(r)"
        }
    }
}
