# NB 参考流程接手计划

> 执行方式：当前会话直接执行；保留既有提交，以独立 feat/nb-takeover 分支交付。

**Goal:** 修复签名基础链，提供实际可运行的签名导出与设备连接探测版本，为手机独立安装/定位收集证据。
**Architecture:** SwiftUI 界面调用签名引擎与只读连接探测。签名产物与含私钥的临时工作目录分开，Zsign 调用序列化。连接探测用 Network.framework 与长度前缀 plist；不发送配对材料。
**Tech Stack:** Swift 5、SwiftUI、Network、ZIPFoundation、Zsign、XcodeGen、GitHub Actions。
**Spec:** ../specs/2026-11-05-nb-takeover.md

## Global Constraints

- iOS 17.0+，当前真机目标 iOS 18.7.3；中文 UI。
- 参考 NB 助手的流程，保留首次电脑安装/配对。
- 不把测试证书、模拟器签名或 QueryType 成功表述为真机可安装/可定位。
- 不修改原 CC GUI 工作区，不读取或上传真实 Apple 凭据、私钥或配对材料。

## Review Focus

1. 返回的 IPA 不因 defer 清理而消失；从真实 async 入口解包产物验证。
2. Zsign 回调不得为空；现有真实签名集成测试覆盖这一边界。
3. application-identifier 在 Entitlements 中，前缀不一定是 TeamIdentifier；使用独立真实形状样例验证。
4. 连接无响应/取消/畸形长度时必须结束，不能无限等待或分配超大内存。
5. CI 测试失败或崩溃必须失败并保留诊断；未执行的测试明确标注，不能据静态检查报绿。

## Task 1: 签名回归与修复

- [ ] 修改 ProfileParserTests，删除错误的根层 application-identifier，增加不同 AppIdentifierPrefix、缺失字段和逆序 XML 边界样例。
- [ ] 修改 IPAPackerTests，从 `await SigningEngine.shared.sign(ipaURL:keyPEM:profile:)` 签名并在返回后读取 IPA；增加错配 Bundle ID、损坏 IPA 的拒绝样例。
- [ ] 执行 XCTest 观察失败；若 CI 认证阻塞，保留测试提交与未执行记录，不能宣称 RED/GREEN。
- [ ] 修复回调、产物路径、清理和 profile 解析；取消测试专用生产入口。
- [ ] CI 增加 resultBundle、原始日志、测试超时及 always 上传诊断。测试通过后再构建 unsigned IPA。

## Task 2: 连接探测和中文操作页

- [ ] 为 plist 帧编码/增量解析编写 XCTest，覆盖分包、连续帧、零长度和超限长度。
- [ ] 实现 Network.framework TCP QueryType 探测，使用明确超时、取消、结果区分。
- [ ] 签名页：文件导入 IPA、PEM 与 profile；调用引擎，导出产物。连接页：地址、探测结果。定位页：明确尚待隧道验证的状态与恢复验证要求。
- [ ] 用户操作要求只显示必要信息，不索取 Apple 账户密码。

## Task 3: 交接与验证

- [ ] 审阅 diff，检查失败与取消路径、输出文件与密钥清理、依赖许可证。
- [ ] 运行可用本地检查，记录 Swift/XCTest/真机未完成项。
- [ ] 如 GitHub 认证可用，推新分支并等待 CI；若凭据不可用，输出可直接运行的推送脚本与代码补丁，明确下一步阻塞。
- [ ] 将本次进度和真机验收步骤存入文档。
