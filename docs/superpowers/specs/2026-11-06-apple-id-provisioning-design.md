# 免费 Apple ID ProvisioningEngine 设计

日期：2026-11-06

状态：用户于 2026-11-06 确认；实施方式 Native

## 目标

LocSign 当前只能导入外部 P12/PEM 私钥和 mobileprovision。此设计增加一条手机内流程：用户输入自己的 Apple ID，在设备上完成 Apple 登录和二次验证，申请或复用开发证书和与当前 iPhone 匹配的描述文件，然后把材料交给现有 `SigningEngine` 生成可安装 IPA。

成功标准是：用户可以在 iPhone 15 Pro Max / iOS 18.7.8 上登录自己的免费账号，看到明确的 2FA 状态，得到与目标设备 UDID 和 IPA Bundle ID 匹配的签名材料，签名页可以使用这些材料完成一次签名；失败时显示可操作的原因，不显示虚假的“已签名”或“已安装”。真实 Apple 请求和安装必须在真机上单独验收，CI 只验证协议编排、错误处理和材料边界。

## 已确认约束

- 免费账号的开发描述文件通常约 7 天到期；证书期限不能在代码中硬编码为 7 天。
- Apple ID 密码只在登录请求期间存在于内存；不写日志、不上传到 LocSign 自建服务、不保存明文。
- 登录会话、Anisette/ADI 状态和本地生成的私钥进入 iOS Keychain，使用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`。提供“退出并清除本机账号资料”入口；iOS 卸载应用不保证删除 Keychain，不能承诺卸载时清理。应用沙盒保存不参与备份的安装标记，首次启动缺少标记时先清除本应用专用 Keychain 命名空间，再建立标记；常规覆盖更新保留标记和凭据。
- Anisette 默认需要外部提供方。XKit 当前默认实现使用 `https://mac-ani.jkcoxson.com` 的 v3 接口；应用必须在首次使用前显示地址、发送的数据类别和可替换/禁用选项。没有 Anisette 时明确提示“无法申请 Apple 材料”，保留手动导入路径。
- 不复制 `SideStore/AltSign`，因为该仓库当前没有可确认的许可证。`SideStore/apple-private-apis` 为 MPL-2.0 Rust，暂不引入 Rust 桥接；如 Swift 路线不可行，另开设计评估。
- Xtool 的 XKit 仓库声明 MIT，包含 GrandSlam 登录、2FA、Anisette 抽象和 Developer Services 客户端；候选固定版本为 `2af0b67447d30063235e2adb7bdc77012f431d3a`，不能直接跟随漂移分支。最终构建前必须保留 MIT 版权、传递依赖许可证和版本清单。
- 免费账号受开发证书配额限制，配额以 Apple 返回结果为准。任何撤销动作都必须在 UI 中列出具体证书及影响并取得用户确认，包括已过期证书；默认先查找仍有效且持有匹配私钥的本地材料。用户目前经 Sideloadly 安装 LocSign，撤销其使用的证书可能影响 LocSign 自身，不能静默替换。

## 方案

新增 `ProvisioningEngine`，只负责 Apple 认证和材料生命周期；现有 `SigningEngine` 仍只接收 `SigningIdentity` 与 `ProvisioningProfileData`，`InstallCoordinator` 仍只负责已签 IPA 的设备安装。这样 Apple 私有接口变化不会改变签名、配对 TLS 或 AFC 层。

适配器分为三层：

1. `AnisetteProvider`：返回 Xcode 风格设备信息、一次性 OTP 和 ADI 状态。用固定版本 XKit 的公开 `RawADIProvider` 注入点接入可配置的 Omnisette v3 适配器；上游具体 `OmnisetteADIProvider` 是 internal，不能假设应用可直接构造它。仅接受 HTTPS/WSS 地址。网络适配器对 HTTP 和 WebSocket 都显式注入基于 `DirectURLSession` 的会话，禁用磁盘缓存和持久 Cookie；Apple 认证字段不能附加到 provider 请求或跨主机重定向。测试使用 fake provider。
2. `AppleAccountClient`：包裹 GrandSlam SRP 登录、Xcode app token 获取和 2FA。它通过 `twoFactorCode` 回调向 UI 请求一次性验证码；错误映射到可读的账号锁定、密码错误、验证码错误、Anisette 失效和网络错误。只展示适配器实际确认的验证方式；上游无法区分短信与受信任设备时显示通用验证码提示，不伪造发送状态。
3. `DeveloperServicesClient`：使用 Xcode token 和 Anisette 请求团队、设备、App ID、证书和 profile。它不接受任意服务器 URL；Apple Developer Services URL 固定在依赖实现中，Anisette URL 单独可配置。所有请求只带当前会话和当前设备所需字段。

首个实现只支持一个主 App、无 appex 或嵌套 App、无需额外 capability 的 IPA。签名前检查归档结构、Info.plist、可执行文件及其 entitlement；App Groups、Push、Associated Domains 等需求不支持时，在注册设备、App ID 或证书前拒绝，并显示原因。手动材料入口继续保留，仍遵守现有签名引擎的扩展限制。

此阶段保留原始 Bundle ID；查询 App ID 必须精确匹配，不能采用上游默认的标识符重写和 capability 增删流程。Bundle ID 不可注册或已有 capability 与本阶段不兼容时，给出明确错误，不擅自改变用户的 IPA 或 Apple 上的配置。

## 数据流

```text
用户输入 Apple ID/密码
        │  (密码只在内存)
        ▼
AnisetteProvider ──> GrandSlam SRP 登录 ──> 2FA 回调
        │                    │
        │                    └── Xcode app token + adsid（Keychain）
        ▼
Developer Services
  ├─ 使用现有 LockdownSession 完成配对 TLS 后读取 UniqueDeviceID
  ├─ 注册或复用设备
  ├─ 查找或创建 IPA Bundle ID
  ├─ 生成本地 RSA 私钥和 CSR，申请/复用开发证书
  └─ 生成 profile（设备 + Bundle ID + 证书）
        │
        ▼
本地材料存储
  ├─ privateKeyPEM（Keychain / 仅本次签名读取）
  ├─ certificateData（短期 Keychain 或受保护缓存）
  └─ mobileprovision（验证 CMS 后保存；在签名适配边界解析为 ProvisioningProfileData）
        │
        ▼
ProvisioningMaterial（私钥 + 已验证 profile + 到期日）
        │
        ▼
现有 SigningEngine → 签名 IPA → 用户点击安装后现有 InstallCoordinator 安装
```

`ProvisioningMaterial` 必须验证：profile 的 Apple CMS 签名有效，TeamIdentifier、application-identifier、ProvisionedDevices、ExpirationDate、DeveloperCertificates 与选定团队、设备、本地私钥/证书一致，并且复用证书时 Keychain 中存在对应私钥。application-identifier 的前缀按 AppIdentifierPrefix 校验，不能假设它永远等于 TeamIdentifier。此流程要求精确的 Bundle ID。证书需在有效期内、存在于 Apple 返回的有效开发证书列表，且其公钥与本地私钥匹配。

新增 `ProvisioningMaterialValidator`，在现有 `ProfileParser` 元数据解析之前验证 CMS SignedData、内容摘要和签名者的 Apple profile 签发链；信任根来源限定 Apple 官方 PKI 并记录指纹和来源，不能信任容器随附的任意根证书或用跳过验证的选项代替。元数据校验必须基于 CMS 验证后得到的已签内容，并确认现有解析器读取的 plist 与该内容一致；拒绝尾随数据或其他未签 plist。现有 `ProfileParser` 只提取 plist，不能被当作此验证器。验证不通过不写入活动材料、不进入签名。证书序列号、profile UUID 和到期日可以显示，私钥、密码、token、ADI blob 和 Anisette OTP 不显示。

## 账户和凭据状态

Keychain 使用本应用专用 service。账号先去除首尾空白并转为小写；登录阶段按账号和 provider 标识隔离，证书与 profile 再按 team ID 隔离，避免登录前尚无 team ID 的循环依赖。第一阶段 UI 只维护一个活动账号。

- `accountSession`：adsid、Xcode token、token expiry、所选 team ID（选择前为空）、provider ID。
- `anisetteState`：XKit provider 所需的 local user UUID、routing info 和 ADI provisioning blob。
- `signingKey`：本地 CSR 生成的 PKCS#8 PEM 私钥；不可导出到 ShareLink 或日志。
- `certificate` 和 `profile`：短期缓存，带材料到期时间和设备/Bundle ID 指纹。清除账户时一并删除。

密码不进入 Keychain；登录结束、失败或取消后立即释放 UI 与适配器持有的密码引用。Swift 字符串不能保证底层内存立即清零，不作该承诺。退出账号只销毁本地 session、删除上述条目并清除签名缓存，不自动撤销 Apple 上的证书。退出会导致本地私钥丢失，UI 明确说明再次申请可能需要撤销旧证书。

替换 provider 会使原 token 和 ADI 状态失效，要求重新登录，但保留仍有效的签名材料；provider ID 包含规范化 endpoint 与协议版本，不能沿用上游对所有地址相同的常量。网络请求失败不删除旧有效材料。生成新私钥后，先持久化为待完成条目再发送 CSR；申请证书已成功而 profile 请求失败时保留该密钥和证书供重试，禁止因为后续失败丢失唯一私钥。新 profile 完成校验后才原子切换活动材料。撤销后旧证书相关缓存必须失效，不能承诺已撤销材料仍可使用。

默认不直接调用 XKit 的高级证书替换或 profile 获取操作：已审阅源码存在过期证书免确认撤销及删除单个已有 profile 的路径。适配器使用下层查询/创建接口，复用有效 profile，创建时只关联目标设备和选定证书；若 Apple 强制删除旧 profile 才能继续，本阶段报错并停止，不自动删除。

## UI 流程

在“签名”页增加“使用 Apple ID 获取签名材料”入口，使用独立的账户 sheet：

1. 展示 Apple ID、Anisette 提供方地址和数据用途。首次启用或更换 provider 前由用户确认：该服务接收生成的本地 UUID、ADI 注册握手消息和 ADI blob，并可看到来源 IP；Apple ID、密码、Xcode token、设备配对记录及签名私钥不发送给该服务。禁用 provider 后仍可使用已有有效材料或手动导入。
2. 输入账号和密码，显示“正在登录”，禁止重复提交；密码字段离开页面立即清空。
3. 若需要 2FA，显示已知的验证方式或通用提示和验证码输入框；验证码每次提交一次，不自动循环重试。错误时允许用户重新登录/验证；若上游已结束认证流程，明确说明需重输密码。取消时结束等待中的回调和请求，回到登录页。
4. 登录成功后显示可用的免费团队；唯一团队自动选中，多个时由用户选择，没有时提示无法继续。此时仅显示已存在材料的状态，不能显示尚未申请的到期时间。
5. 用户选择 IPA 和已配对设备后点击“获取材料并签名”。先做本地 IPA 检查和 TLS 后的 UDID 核对，再申请材料。若需撤销旧证书，展示精确列表、对其他已签 App 和 LocSign 自身可能的影响，默认取消；拒绝不发撤销请求。签名成功后显示材料到期时间和 IPA 导出结果，满足现有配对条件后才能点击“安装到已配对手机”。
6. Apple ID 登录失败、Anisette 不可用、设备未注册、Bundle ID 冲突、频率限制和材料过期分别显示原因与下一步。失败时清理临时解包文件和无效 profile；按凭据状态规则保留可重试的私钥/证书与旧有效材料。

从登录、等待 2FA、申请到签名期间禁止重复提交和切换 IPA、设备或团队；退出/取消使当前操作编号失效，迟到响应不能恢复登录、覆盖材料或设置成功。取消不能回滚 Apple 已完成的注册或撤销；普通取消保留已持久化的待完成密钥，重试先查询远端状态；明确“退出并清除”则删除该账号全部本地条目，迟到响应不得重新写入。

## 接口草案

```swift
struct ProvisioningTeam: Sendable {
    let id: String
    let name: String
}

struct ProvisioningAccount: Sendable {
    let id: UUID                         // opaque local session handle; no token
    let appleID: String
    let teams: [ProvisioningTeam]        // supported free teams only
}

struct ProvisioningRequest: Sendable {
    let accountID: UUID
    let teamID: String
    let ipaURL: URL
    let deviceUDID: String               // obtained after pairing TLS
}

struct CertificateRevocation: Sendable {
    let id: String
    let serialNumber: String
    let name: String
    let expiry: Date
}

struct ProvisioningMaterial: Sendable {
    let privateKeyPEM: String            // returned only to SigningEngine
    let profileData: Data               // validated CMS; parsed at signing boundary
    let certificateExpiry: Date
    let profileExpiry: Date
}

protocol ProvisioningEngine: Sendable {
    func logIn(
        appleID: String,
        password: String,               // transient; never in provision request
        twoFactorCode: @escaping @Sendable () async -> String?
    ) async throws -> ProvisioningAccount
    func restoreAccount() async throws -> ProvisioningAccount?
    func provision(
        request: ProvisioningRequest,
        confirmRevocation: @escaping @Sendable ([CertificateRevocation]) async -> Bool
    ) async throws -> ProvisioningMaterial
    func logout(account: String) async throws
}
```

引擎实现使用 actor 串行管理状态；所有操作支持 Task 取消，并以操作编号防止 actor 重入导致过期响应提交。`restoreAccount()` 只返回未过期、provider 一致的有效会话，返回空值时 UI 要求登录。UI 只拿到不含 token 的本地会话句柄；`provision` 再校验该句柄和团队归属。provider 配置通过构造依赖提供，设置变化时取消当前操作并重建适配器。

实现不得把 `password`、`privateKeyPEM`、token 或 Anisette 数据放入 `AppLogger`，也不记录原始认证响应。`ProvisioningMaterial` 交给 `SigningViewModel` 后，将已经验证的 `profileData` 解析为现有 `ProvisioningProfileData`，与私钥一起立即传给 `SigningEngine`；不长期保存在 ViewModel。现有 `ProvisioningProfileData.payload` 含 `[String: Any]`，不声明其为 `Sendable`，不使用 `@unchecked Sendable` 绕过隔离。现有 `SigningIdentity.pem` 的临时文件生命周期仍由签名引擎负责清理。

## 失败与回退

- Apple 登录或 2FA 失败：不创建证书，不改变已缓存材料。
- Anisette provider 超时/返回不完整：显示 provider 地址和重试按钮；允许用户改用手动 P12/profile。
- Apple Developer Services 返回频率限制：停止并提示稍后重试，不把撤销证书当作重试方法。免费证书配额已满：优先复用持有私钥的匹配证书；只有用户确认具体列表后才撤销，远端状态变化需要重新确认，不能扩展删除范围。
- 设备或 Bundle ID 不匹配：在签名前阻止，不进入 AFC。
- profile 解析或 CMS 无效：删除本次 profile 缓存并报错；必须先验证 Apple CMS 签名，不能只读取 plist payload 就当作 Apple 已签发。
- 安装失败：沿用现有安装错误和清理路径，显示“签名成功，安装失败”，不能显示“已安装”。

## 测试和验收

单元测试（不使用真实账号）：

- SRP/GrandSlam 响应状态映射和 2FA 回调：成功、错误验证码、取消、二次验证失败。
- Anisette provider：完整数据、超时、错误 JSON、provider ID 改变时清除旧 ADI 状态。
- Developer Services 编排：设备已存在/首次注册、App ID 精确匹配、无私钥时不能复用证书、包括过期证书在内的撤销前确认、拒绝后没有删除请求、profile 设备和 Bundle ID 校验、不删除旧 profile、不修改 capability。
- Keychain：密码不写入、token/ADI/私钥隔离、退出清理、重新安装标记缺失时清理、常规更新保留、旧有效材料在网络失败后保留、新证书成功但 profile 失败时可恢复私钥、锁屏或写入失败不发送 CSR。
- 材料一致性：私钥与证书不匹配、profile 过期、profile 缺设备、CMS 无效、非 Apple 签发链、AppIdentifierPrefix 与 TeamIdentifier 不同、扩展和不支持的 entitlement。
- SigningViewModel：2FA sheet 状态、重复提交锁定、无团队/多团队、取消及退出后迟到响应无效、错误清理和签名成功后才启用输出/安装。
- 网络边界：provider URL 校验、HTTP/WebSocket 注入、认证字段不出现在 provider 请求、跨主机重定向不能带出凭据、日志和缓存中无敏感数据。

CI 只运行 fake provider 和本地 HTTP fixture，禁止真实 Apple ID、真实 Anisette、真实 token 或私钥进入环境。真机验收分三步记录：免费账号登录/2FA；申请或复用材料并签名；用已验证的配对和 LocalDevVPN 安装并启动一个无扩展 IPA。定位服务不属于本设计。

## 依赖与许可

候选依赖为 [xtool/XKit 固定版本](https://github.com/xtool-org/xtool/tree/2af0b67447d30063235e2adb7bdc77012f431d3a)，只接入 XKit 产品及其必需依赖；在仓库和 App 的许可页保存 LICENSE、依赖版本与许可证清单。其 Package.swift 要求 Swift tools 6.2，不能假设当前 macos-15 默认 Xcode 已满足；CI 必须显式选择经过探针验证、包含 Swift 6.2 的 Xcode，模拟器按该工具链实际可用设备选择。iOS deployment target 保持 17.0。

进入实现时先用最小 target 验证解析、模拟器链接和 iPhone Release 链接，特别检查 XKit 的 xtool-core/OpenSSL 与现有 OpenSSL/Zsign 是否出现同名模块、重复符号或不支持 iOS 的传递依赖；同时验证网络和 Keychain 的公开注入接口。只改为可解析不算通过。探针通过后固定解析出的传递依赖版本，再实施业务流程；不能为通过探针降低 TLS 或材料验证要求。依赖无法收敛时记录具体诊断并评估替代接入方式。

XKit 的远程 Omnisette provider 是第三方服务；Apple 私有接口变化、账号限制和 provider 不可用均以错误状态呈现，不承诺第三方服务长期可用。参考源码的本地副本位于工作区 `work/references/provisioning/`，其中证书、profile、App ID 和 ADI 实现已暴露上述必须覆盖的默认行为。

## 非目标

- 不实现企业证书、付费签名、多人账号、共享证书或第三方代签。
- 不保存 Apple ID 密码，不自建账号代理，不绕过 2FA，不承诺规避 Apple 频率限制。
- 不在本阶段加入定位、DDI 挂载、后台保活或 App Store 降级。
- 不把签名材料申请成功等同于设备安装成功；安装仍由现有 `InstallCoordinator` 和真机验收证明。
