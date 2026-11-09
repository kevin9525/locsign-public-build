import Foundation

enum InstallationStep: String {
    case readPackage = "读取待安装 IPA"
    case readPairing = "读取配对文件"
    case connectDevice = "连接设备"
    case authenticate = "配对认证"
    case readDevice = "读取设备标识"
    case startAFC = "启动文件服务"
    case startInstaller = "启动安装服务"
    case connectAFC = "连接文件服务"
    case connectInstaller = "连接安装服务"
    case prepareUpload = "准备上传目录"
    case upload = "上传 IPA"
    case sendInstall = "发送安装请求"
    case waitForResult = "等待安装结果"
}

enum InstallationFailure {
    static let domain = "LocSign.Installation"

    static func wrapping(_ error: Error, at step: InstallationStep) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        let cause = error as NSError
        // The installation client has more precise send/receive context than
        // the coordinator. Preserve that context and the original cause once.
        if cause.domain == domain { return error }
        return NSError(domain: domain, code: cause.code, userInfo: [
            NSLocalizedDescriptionKey: "\(step.rawValue)失败：\(cause.localizedDescription)",
            NSUnderlyingErrorKey: cause
        ])
    }
}
