# IPA 导入信息预览实施计划

> 执行方式：主代理按 executing-plans 在当前已隔离工作树实施，复用已有代理审查，禁止新增下级代理。

**目标：** 导入 IPA 后立即展示应用名、版本、原应用标识、大小、扩展数量和自动签名兼容性提示。

**架构：** 新增独立 `IPAImportPreviewInspector`，有界读取 ZIP 中的 Info.plist，再调用现有严格预检。SigningViewModel 在后台完成复制与预览，并在确认未取消后一次提交文件与预览；预览失败不阻断已有手动签名流程。SigningView 在选择卡片下展示结果。

**技术：** Swift、SwiftUI、ZIPFoundation、XCTest、GitHub Actions / Xcode 26。

**需求来源：** 会话中已批准的 IPA 预览方案及用户“继续”指令。

## 约束

- 中文文案，不改变已有手动证书签名能力。
- 自动签名前仍严格检查，不把预览通过描述为安装成功保证。
- 扩展数量为主 App 的 PlugIns 下的直接扩展；不将所需标识数描述成新增注册数或剩余额度。
- 取消不替换已有文件；锁保持到后台清理完毕，不能发布旧回报。
- 当前 linked worktree 复用为 `feat/ipa-import-preview`；无合并主分支、无真机安装。

## 审查重点

1. 取消发生在复制之前、检查期间、后台结束之后：均保留旧文件与预览。
2. 换成无效或缺失元数据的 IPA：不能沿用上一份预览或兼容状态。
3. 加密或不支持的主程序：仍显示可读应用信息，给出自动签名限制。
4. 多主应用、重复路径、symlink、超大 plist：不能选择任意元数据冒充唯一主应用。
5. 不同来源元数据、缺字段、扩展：显示准确，失败原因脱敏。

## 任务 1：导入原子性与预览读取

文件：`SigningViewModel.swift`、新建 `IPAImportPreview.swift`、`SigningViewModelTests.swift`、新建 `IPAImportPreviewTests.swift`。

- [x] 在现有导入 API 上写取消回归：先选 first.ipa；预先取消 Task 后尝试 second.ipa；断言 ipaName 仍为 first.ipa，个人标识仍为原值。
- [x] 提交 tests-only 并执行现有 build workflow；确认 XCTest 断言失败，而非编译失败。
- [x] 写真实 ZIP fixtures 覆盖 metadata、版本缺省、extensions、unsupported 二进制、无效结构、plist 上限；覆盖导入替换、取消时临时文件清理和旧预览保留。
- [x] 实现 `IPAImportPreviewInspector.inspect(_:) throws -> IPAImportPreview`，最多扫描 50,000 entries、单个 plist ≤ 1MiB，累计读取 plist ≤ 16MiB；读取不解压任意路径。
- [x] preview 存储 bundleID、name、version、build、minimumOSVersion、fileSize、extensions、automaticSigningIssue。
- [x] 注入 `inspectPreview`；`importFile` 改为返回成功 Bool，使用 cancellation handler 传播到 worker，提交前检查取消；取消入口使导入失效并等待 worker 清理。
- [x] 恢复签名标识时复用已通过预检的 bundleID，签名时保留再次严格验证。

## 任务 2：界面、验证与交付

文件：`SigningView.swift`、新建 `IPAImportPreviewView.swift`、`project.yml`、验收文档。

- [x] 卡片下加入预览和兼容提示；导入时提供取消，未成功导入时不恢复账号签名设置。
- [x] 将版本递增至 0.5.5 / 37。
- [x] 执行 `python -m unittest discover -s Tests/BuildTools -v` 与 `git diff --check`。
- [x] 复用审查代理检查分支 diff，解决实际问题。
- [x] 提交推送、运行完整云端 workflow，要求所有 XCTest/native/打包检查及设备构建通过。
- [x] 创建 draft PR（base `feat/connection-self-check`）；下载 IPA 并核验外层 artifact 与内层 IPA 摘要、版本、架构、资源。
- [x] 输出中文使用说明、验证证据和可点击交付路径，注明真机验收尚未执行。
