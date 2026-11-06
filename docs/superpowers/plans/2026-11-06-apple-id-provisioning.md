# 免费 Apple ID ProvisioningEngine Implementation Plan

> REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox syntax.

**Goal:** 在 LocSign 中加入免费 Apple ID 登录、2FA、开发证书与 mobileprovision 申请/复用流程，并把已验证材料接入现有签名和安装链路。

**Architecture:** 以 actor 实现独立 ProvisioningEngine，通过 AppleAccountClient、AnisetteProvider 和 DeveloperServicesGateway 包裹固定版本 XKit。Keychain、CMS profile 验证和 Developer Services 编排在独立模块中完成；现有 SigningEngine 和 InstallCoordinator 保持设备签名与安装职责。

**Tech Stack:** Swift/SwiftUI、Security、现有 OpenSSL/Zsign/ZIPFoundation、XKit commit 2af0b67447d30063235e2adb7bdc77012f431d3a、XcodeGen、XCTest、GitHub Actions macos-15。

**Spec:** docs/superpowers/specs/2026-11-06-apple-id-provisioning-design.md

## Global Constraints

- iOS deployment target 保持 17.0；XKit 的 Swift tools 6.2 必须先通过 simulator 和 iphoneos 链接探针。
- Apple ID 密码、Xcode token、ADI blob、Anisette OTP、私钥和配对数据不能进入 AppLogger、测试输出、ShareLink 或第三方 provider 请求。
- Keychain 使用本应用专用 service 和 kSecAttrAccessibleWhenUnlockedThisDeviceOnly；退出清除入口删除本应用命名空间，不能承诺卸载自动清理。
- Anisette 只允许 HTTPS/WSS；默认地址 https://mac-ani.jkcoxson.com、数据类别和来源 IP 对用户可见，provider ID 变化时重新登录。
- 第一阶段只接受一个主 App、无 appex/嵌套 App、原始 Bundle ID 精确匹配且无需额外 capability 的 IPA。
- 复用证书必须同时拥有匹配私钥并通过证书有效期和公钥匹配校验；撤销前列出具体证书并取得确认。
- profile 必须先通过 Apple CMS SignedData、签发链、摘要和 plist 内容一致性验证，再交给 ProfileParser。
- 失败时保留旧有效材料；签名成功和安装成功分别显示。
- CI 只使用 fake provider、fake Developer Services 和本地 fixture，不使用真实 Apple ID、token、Anisette 或私钥。

## Review Focus

1. 依赖与工具链：XKit Swift tools 6.2、OpenSSL 和 OpenAPI 传递依赖必须同时通过 simulator 与 iphoneos 链接。
2. CMS 与材料一致性：未签名、错误签发链、尾随 plist、过期 profile、AppIdentifierPrefix 差异、证书与私钥不匹配都必须拒绝。
3. 远端副作用：证书撤销只能在确认且远端列表未变化时发生；拒绝不能发送删除请求。
4. 敏感数据边界：密码、token、ADI、私钥不写日志、不进入 provider 请求、不进入普通磁盘缓存；Keychain 写入失败时不得发送 CSR。
5. 异步竞态：2FA 等待、取消、退出或重复提交后，迟到响应不能覆盖新账号、材料或 UI 状态。

---

### Task 1: 固定 XKit 依赖并完成编译探针

Files:
- Create App/Sources/Provisioning/XKitProbe.swift
- Modify project.yml and .github/workflows/build.yml
- Create docs/dependencies/XKit.md and docs/dependencies/licenses/xtool-MIT.txt

Interfaces:
- XKitProbe.touch() -> String 引用 DeveloperServicesLoginManager 和 DeveloperAPIClient，证明公开模块可链接。

Steps:
- [ ] 在 project.yml 固定 xtool URL/revision，加入 XKit 产品和 XKitProbe.swift。
- [ ] 运行 xcodegen generate 与 xcodebuild -resolvePackageDependencies；解析失败时停止后续实现并保存日志。
- [ ] 运行 simulator 和 iphoneos 两个 xcodebuild build 探针，记录 Xcode、Swift、Package.resolved 版本及 OpenSSL/重复符号诊断。
- [ ] 保存 XKit MIT 与传递依赖许可证清单，运行 git diff --check 后提交 build: probe fixed XKit dependency。

Expected result: 两个 build 都退出 0；否则只提交诊断文档并回到替代依赖评估。

### Task 2: 建立凭据存储、类型和操作状态边界

Files:
- Create App/Sources/Provisioning/ProvisioningTypes.swift
- Create App/Sources/Provisioning/ProvisioningKeychain.swift
- Create App/Sources/Provisioning/ProvisioningOperation.swift
- Create focused XCTest files

Interfaces:
- ProvisioningTeam、ProvisioningAccount、ProvisioningRequest、CertificateRevocation、ProvisioningMaterial 与设计文档字段一致。
- ProvisioningKeychain 提供 read(account:provider:team:key:), write, remove 和 removeAll(account:)。
- ProvisioningOperation actor 提供 begin() -> UUID、isCurrent(_:) -> Bool、cancel() -> UUID。

Steps:
- [ ] 先写 Keychain spy 测试，验证规范化账号、固定 service、kSecAttrAccessibleWhenUnlockedThisDeviceOnly、只删除本应用 namespace，以及更新失败保留旧值。
- [ ] 用 SecItemUpdate 原子更新、缺失时 SecItemAdd，禁止先删后写；加入首次安装标记缺失时清理入口。
- [ ] 写操作编号 actor；每次登录、申请、退出在写入或返回前检查取消和 UUID。
- [ ] 运行 focused XCTest 并提交 feat: add provisioning credential boundaries。

### Task 3: 验证 CMS profile 并建立材料校验器

Files:
- Create App/Sources/Provisioning/ProvisioningProfileValidator.swift
- Modify App/Sources/Infra/ProfileParser.swift
- Create validator tests and deterministic CMS fixtures

Interfaces:
- ProvisioningProfileValidator.validate(data:expectedBundleID:expectedTeamID:expectedUDID:expectedCertificateDER:) -> ValidatedProvisioningProfile。
- ValidatedProvisioningProfile 保存原始 CMS、已验证 plist、ProfileParser 结果、UUID、证书 DER 和到期日；不声明为 Sendable。

Steps:
- [ ] 先写 unsigned、错误签发链、CMS 外尾随 plist、过期、UDID/Bundle ID/Team mismatch 和证书私钥 mismatch 的失败测试。
- [ ] 使用现有 OpenSSL 的 d2i_CMS_ContentInfo 和 CMS_verify 验证 SignedData、唯一 signer、摘要/签名、完整输入消费与 Apple 签发链；明确加载 Apple 官方 PKI 根，测试注入 fixture trust root。CMSDecoder 和 SecPolicyCreateiPhoneProvisioningProfileSigning 不作为 iOS 公开 API 使用。
- [ ] 将 CMS 解出的 plist 与 parser 边界内容逐字节比较，再做 TeamIdentifier、AppIdentifierPrefix、精确 Bundle ID、UDID、证书和有效期校验。
- [ ] 在任何 Keychain 写入或 Developer Services mutation 前完成验证，运行 focused XCTest 并提交 feat: validate signed provisioning profiles。

### Task 4: 建立 Anisette 网络隐私边界

Files:
- Create App/Sources/Provisioning/AnisetteProvider.swift and XKitHTTPClientAdapter.swift
- Modify App/Sources/Infra/DirectURLSession.swift
- Create AnisetteProviderTests.swift

Interfaces:
- AnisetteProviderConfiguration(endpoint:) 只接受 HTTPS/WSS，并公开 providerID 和 privacySummary。
- XKitHTTPClientAdapter 实现 XKit HTTPClientProtocol；HTTP 和 WebSocket 都使用 ephemeral session、无缓存、无持久 Cookie。

Steps:
- [ ] 写 HTTP endpoint、跨 host redirect、ephemeral/urlCache/cookie 和 Apple header 泄漏测试。
- [ ] 实现显式 URLSession adapter：connectionProxyDictionary 为空、cookies/cache 为空、HTTPS/WSS 使用系统 trust、跨 host redirect 拒绝。
- [ ] 通过 XKit RawADIProvider 和 ADIDataProvider 注入自定义 client 与 Keychain-backed storage；provider ID 变化时 resetProvisioning、删除旧 ADI 并要求重新登录。
- [ ] 运行 focused XCTest 并提交 feat: isolate Anisette provider traffic。

### Task 5: 包装 Apple ID 登录、2FA 和团队发现

Files:
- Create AppleAccountClient.swift and AppleAccountError.swift
- Create AppleAccountClientTests.swift

Interfaces:
- AppleAccountAuthenticating.logIn(appleID:password:twoFactorCode:) async throws -> ProvisioningAccount。
- TwoFactorCodeProvider 是 Sendable async closure；ProvisioningAccount 只含 opaque session handle、规范化 Apple ID 和团队列表。

Steps:
- [ ] 用 fake GrandSlam 测试成功、密码错误、账号锁定、Anisette 缺失、验证码错误可重试和验证码取消；断言 callback 每次一次且 logger 无敏感字段。
- [ ] 调 XKit DeveloperServicesLoginManager.logIn，通过 delegate 等待验证码，规范化 Apple ID，映射错误并在所有返回路径释放密码引用。
- [ ] 用 DeveloperServicesClient 的 team list 获取团队，仅返回支持 iOS 的免费团队；0 个报 noDeveloperTeam，多团队交 UI 选择。
- [ ] 运行 focused XCTest 并提交 feat: add Apple ID login and two-factor flow。

### Task 6: 实现精确 Developer Services 编排

Files:
- Create DeveloperServicesGateway.swift and DeveloperServicesProvisioner.swift
- Create DeveloperServicesProvisionerTests.swift

Interfaces:
- Gateway 提供 listDevices、registerDevice、findExactBundleID、listCertificates、createDevelopmentCertificate、listProfiles、createDevelopmentProfile、revokeCertificate。
- DeveloperServicesProvisioner.provision(request:account:confirmRevocation:) async throws -> PendingMaterial。

Steps:
- [ ] 用记录型 fake 覆盖设备复用/注册、App ID 精确匹配、证书复用需私钥、过期证书拒绝、profile mismatch、unsupported entitlement 无远端 mutation。
- [ ] 用 IPAPacker 解包到 protected temp；要求一个 app、合法 Info.plist/Mach-O、无 PlugIns/嵌套 app，并拒绝 App Groups、Push、Associated Domains。
- [ ] 精确复用或注册设备与原始 Bundle ID；不调用 XKit sanitizer、capability 删除或 profile 删除路径。
- [ ] 证书配额不足时列出 revocation candidates；确认后重新拉取并比较 ID/serial/expiry，变化或拒绝都停止。
- [ ] 只用目标设备、App ID 和证书创建 profile，先经过 ProfileValidator；旧 active material 只在完整成功后切换，profile 失败保留 pending key/certificate。
- [ ] 运行 focused XCTest 并提交 feat: provision exact device profiles。

### Task 7: 组合 actor ProvisioningEngine

Files:
- Create ProvisioningEngine.swift and ProvisioningEngineLive.swift
- Create ProvisioningEngineTests.swift

Interfaces:
- 实现设计文档中的 logIn、restoreAccount、provision、logout(account:)。
- Actor 持有 session、active team、pending material 和 operation generation；不保存 [String: Any] 或 ProvisioningProfileData。

Steps:
- [ ] 写 delayed fake race tests，验证取消、退出和迟到响应不能提交 Keychain、切换材料或恢复 UI；测试 token expiry/provider mismatch、旧材料保留、profile failure 保留 pending key。
- [ ] 公开操作生成 UUID；校验 session/team 后再发网络请求，2FA 回调、CSR 写入、profile 验证、材料切换和 UI 返回前都检查取消与 UUID。
- [ ] 只有 CMS、证书公钥、UDID/Bundle/Team 全部通过才原子切换并返回 ProvisioningMaterial。
- [ ] 运行 focused XCTest 并提交 feat: compose provisioning engine。

### Task 8: 接入签名页、安装状态、日志和 CI

Files:
- Modify SigningViewModel.swift and SigningView.swift
- Create AppleIDProvisioningSheet.swift, SigningProvisioningViewModelTests.swift
- Create ProvisioningRedaction.swift and tests
- Modify AppLogger.swift, build.yml and README.md

Interfaces:
- SigningViewModel 注入 ProvisioningEngine 和 paired device probe；增加 provisioningState、provisioningError、provisionAndSign(...)。
- Sheet 管理 provider disclosure、Apple ID/password、2FA、team、revocation confirmation、cancel/logout。
- ProvisioningRedaction.redact(_:) -> String；provisioning event 统一脱敏。

Steps:
- [ ] 写 provider disclosure 未确认、重复提交、2FA cancel、无 team、revocation reject、UDID mismatch、签名失败和安装失败测试。
- [ ] 先做 paired TLS probe 和 UDID compare，再执行本地 IPA 检查和 ProvisioningEngine.provision；冻结输入，解析 profile CMS 后调用 SigningEngine；只有 output URL 返回才允许安装。
- [ ] UI 展示 provider endpoint、数据类别、来源 IP、team、到期日和精确撤销列表；密码在提交/取消/离开页面清空，活动期间禁用切换。
- [ ] 统一 logger redaction，CI 加 focused provisioning tests、双平台探针、result bundle 和原始日志；README 记录 iPhone 15 Pro Max、iOS 18.7.8、LocalDevVPN 10.7.0.1 的真机步骤，但不记录敏感值。
- [ ] 运行 Python 打包测试、全量 XCTest、iphoneos unsigned build、git diff --check 和 git status；确认输出后提交 feat: connect Apple ID provisioning UI。

## Plan Self-Review

- Spec coverage: Task 1 covers dependency/toolchain/license; Task 2 Keychain/installation marker/operation generation; Task 3 CMS/trust/semantic checks; Task 4 provider disclosure/network/ADI; Task 5 login/2FA/team; Task 6 exact device/App ID/certificate/profile and guarded revocation; Task 7 actor cancellation and atomic materials; Task 8 UI/signing/install/redaction/CI/real-device acceptance.
- Placeholder scan: every step names concrete files, interfaces, commands and expected outcomes; no unresolved implementation marker remains.
- Type consistency: ProvisioningMaterial.profileData remains Data, gateway signatures are repeated consistently, and actor state never stores non-Sendable plist dictionaries.
- Review Focus coverage: all five risks have explicit owning tasks and tests.
