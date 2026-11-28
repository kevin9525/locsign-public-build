import SwiftUI

struct IPAImportPreviewView: View {
    let preview: IPAImportPreview

    var body: some View {
        LabeledContent("应用名称", value: preview.name)
        LabeledContent("版本", value: preview.version ?? "未提供")
        if let build = preview.build { LabeledContent("构建版本", value: build) }
        LabeledContent("原应用标识") {
            Text(preview.bundleID ?? "未提供").textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
        LabeledContent("文件大小", value: ByteCountFormatter.string(fromByteCount: preview.fileSize, countStyle: .file))
        if let minimum = preview.minimumOSVersion {
            LabeledContent("声明的最低系统", value: "iOS \(minimum)")
        }
        if preview.extensions.isEmpty {
            LabeledContent("App 扩展", value: "0 个")
        } else {
            DisclosureGroup("App 扩展（\(preview.extensions.count) 个）") {
                ForEach(preview.extensions.prefix(20)) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                        Text(item.bundleID ?? "未提供应用标识")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if preview.extensions.count > 20 {
                    Text("另有 \(preview.extensions.count - 20) 个扩展未展开显示。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if let issue = preview.automaticSigningIssue {
            VStack(alignment: .leading, spacing: 6) {
                Label("自动签名预检未通过", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(issue).font(.footnote).textSelection(.enabled)
                Text("手动证书签名仍可尝试，实际支持情况由签名和安装结果确定。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("自动签名预检通过", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Text("主应用和扩展共需 \(preview.extensions.count + 1) 个应用标识；这不是新增注册数或账号剩余额度。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("预检仅检查包格式和已知签名限制，不保证设备兼容、签名或安装成功。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
