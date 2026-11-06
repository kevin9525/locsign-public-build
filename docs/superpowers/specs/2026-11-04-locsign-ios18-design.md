# LocSign 设计文档 —— iOS 18 设备端自签 + 虚拟定位工具

日期：2026-11-04
状态：已确认（用户委托确认，2026-11-04）
工作代号：LocSign（正式名后续可改）

## 1. 背景与目标

开发一个安装在 iPhone 上的工具类 App（IPA），目标系统 iOS 18.x，免越狱，供机主本人使用。两个核心功能：

1. **设备端自签**：使用机主自己的免费 Apple ID，在设备上为 IPA 文件完成签名并安装，签名有效期 7 天，需支持续签提醒与给自己续签。
2. **全局虚拟定位**：固定选点（地图选点/地址搜索）后一键将设备 GPS 全局模拟到该点，所有读取 CoreLocation 的 App 生效；支持一键恢复真实定位。

参考产品：NB全能助手（nbtool8.com，闭源商用）。本项目为个人自用版本，技术路线站在开源实现上：设备端签名参照 Feather / SideStore，定位协议移植 pymobiledevice3。

## 2. 用户与使用边界

- 用户：机主本人，一人使用，无账号体系、无内购、无多语言需求。
- 用途定位：个人测试与隐私场景的自签与定位模拟（如测试应用的定位行为、个人隐私保护）。
- 明确不覆盖：分发给他人、商业化签名服务、规避特定服务条款的用途。

## 3. 约束与前提

| 约束 | 内容 |
| --- | --- |
| 目标系统 | iOS 17.0 – 18.x（重点 iOS 18；17 以下不承诺支持） |
| 越狱状态 | 不依赖越狱；但**必须开启开发者模式**（虚拟定位硬性前提） |
| 签名账号 | 免费 Apple ID：单证书 7 天有效、同时最多 3 个自签 App、AppID 注册有频率限制 |
| 开发环境 | 开发机为 Windows，无 Xcode；全部代码 + CI 配置在本机编写 |
| 构建方式 | GitHub Actions macos runner 云端构建出 IPA，artifact 下载安装 |
| 私有 API | 签名、安装、定位三条链路全部依赖私有协议/私有接口，无官方文档，参照开源实现 |

## 4. 非目标（Non-Goals）

- 不做商业化：多用户、付费签名、企业证书分发、超级签名。
- 不做轨迹模拟与游戏摇杆（后续版本再议）。
- 不做 iOS 16 及以下支持（旧版 DDI 挂载协议是另一套）。
- 不做上架 App Store（依赖私有 API，只能侧载）。
- 不做 PC 端配套软件（M0 spike 阶段的 Python 脚本除外，属于一次性验证工具）。

## 5. 总体架构

```
┌─ iPhone (iOS 18, 开发者模式 ON, 免越狱) ──────────────┐
│  SwiftUI App (LocSign)                                │
│  ┌────────┐  ┌────────────┐  ┌─────────────────────┐ │
│  │ UI 层  │→ │ Signing    │→ │ InstallEngine       │ │
│  │ 3 Tab  │  │ Engine     │  │ 自连本机 lockdownd   │ │
│  └────────┘  └────────────┘  └─────────────────────┘ │
│       │         ↑ ProvisioningEngine(Apple ID+证书)   │
│       ↓                                              │
│  LocationEngine: DDI挂载 → 系统定位模拟(全局生效)      │
└──────────────────────────────────────────────────────┘
GitHub Actions (macos runner) ← 源码推送 → 出 IPA artifact
```

App 内部完全自洽：签名、安装、定位均在设备上完成，无需 PC 配合（首次生成 pairing 文件时需要一次 PC）。

## 6. 模块设计

每个模块单一职责、可独立理解与替换。

### 6.1 UI 层（SwiftUI）

- **职责**：三个页签的界面与交互；不做业务逻辑。
- **签名页**：IPA 导入（文件 App / URL 下载）→ 选择证书与描述文件 → 签名进度 → 安装按钮；已装应用列表与各自签名到期时间。
- **定位页**：MapKit 地图选点、地址搜索；当前模拟状态展示；「应用定位」「恢复真实定位」两个动作。
- **证书页**：Apple ID 登录（账号 + 密码 + 2FA 处理）、证书/描述文件/设备列表、7 天到期倒计时与提醒开关。
- **依赖**：各 Engine 暴露的异步接口（async/await），UI 不直接触碰私有协议。

### 6.2 SigningEngine（Swift + C/C++ 混编）

- **职责**：输入 IPA + p12 证书 + mobileprovision + entitlements，输出重签后的 IPA。
- **实现**：开源 ldid（C++，MIT）编译为 iOS 静态库，负责 MachO 重签与 entitlements 注入；ZIP 解包/重打包用 ZIPFoundation；描述文件与证书用 Security.framework 解析。
- **接口**：`sign(ipa, identity, profile, entitlements) async throws -> SignedIPA`。
- **依赖**：ldid、ZIPFoundation。

### 6.3 ProvisioningEngine（Apple ID 证书链路）

- **职责**：用免费 Apple ID 完成认证 → 注册 AppID → 生成 7 天开发证书 → 下载 mobileprovision。
- **实现**：参照 SideStore 开源的 libprovision 调用 developerservices2.apple.com 私有接口；anisette 数据设备端生成（SideStore 方案），失败回退公共 anisette 服务器；处理 2FA（ trusted device 验证码）。
- **接口**：`login(account, password) -> Session`、`createOrReuseCertificate(session) -> p12 + profile`。
- **风险控制**：免费账号签名请求频率限制——同一 AppID 复用、证书复用到过期、请求节流。
- **依赖**：libprovision（Swift 包）、anisette 组件。

### 6.4 InstallEngine（设备自装链路）

- **职责**：把重签后的 IPA 安装到本机。
- **实现**：通过本机局域网地址自连自身 lockdownd（62078 端口，SideStore minimuxer 思路），持 pairing 文件完成 TLS 配对，走 installation_proxy + AFC 上传并安装。
- **接口**：`install(signedIPA, pairing) async throws`；`listInstalled() -> [AppInfo]`。
- **前提**：pairing 文件由 M0 阶段在 PC 上用 pymobiledevice3 一次性生成并导入；换机/重置后重新生成。
- **依赖**：自研 usbmux/lockdownd 协议实现（Swift，参照 minimuxer）。

### 6.5 LocationEngine（定位模拟链路）

- **职责**：全局模拟 GPS 到指定坐标；恢复真实定位。
- **实现**（全部移植自 pymobiledevice3，协议细节以其源码为准）：
  1. 检测开发者模式状态，未开启则引导用户到 设置 → 隐私与安全性 → 开发者模式 打开并重启。
  2. Personalized Developer Disk Image 在线挂载：向 Apple 个性化签名服务请求签名（需设备 ECID 与证书信息），下载 cryptex 并挂载。
  3. 通过 DVT instruments 通道发送 SimulateLocation 消息设置坐标。
  4. 恢复：发送 stop/空坐标消息；重启设备是兜底恢复手段。
- **接口**：`ensureReady() async throws`（DDI 就绪）、`simulate(lat, lng) async throws`、`restore() async throws`、`status() -> SimState`。
- **依赖**：自研 DDI 个性化挂载（Swift）、DVT 协议实现（Swift）。

### 6.6 Infra（基础设施）

- **职责**：bplist/plist 编解码、HTTP 客户端封装、日志（分级别、落盘可导出）、统一错误码。
- **依赖**：无外部重依赖，保持轻量。

## 7. 关键数据流

### 7.1 签名安装流

```
导入IPA → ProvisioningEngine(取/续证书) → SigningEngine(重签)
       → InstallEngine(自连lockdownd安装) → 证书倒计时提醒
```

### 7.2 定位模拟流

```
地图选点 → ensureReady(开发者模式检查→DDI挂载) → simulate(lat,lng)
        → 系统全局生效 → (随时) restore() 或重启恢复
```

### 7.3 自续签流（M3）

```
到期前提醒 → App 对自身 bundle 重签（用当前证书重写自身描述文件）
          → installation_proxy 覆盖安装自身
```

## 8. 错误处理策略

| 失败点 | 用户可见话术 | 恢复动作 |
| --- | --- | --- |
| Apple ID 认证失败/2FA 超时 | 「登录失败：验证码超时，请重试」 | 重走登录 |
| 签名请求被 Apple 拒绝（限频） | 「请求过于频繁，稍后再试」 | 节流 + 复用既有证书 |
| 证书/描述文件过期 | 「证书已过期 N 天，请续签」 | 一键续签 |
| 开发者模式未开启 | 「请先开启开发者模式（附引导步骤）」 | 跳转系统设置指引 |
| DDI 挂载失败 | 「组件挂载失败，点此重试」 | 重试挂载（含网络检查） |
| lockdownd 自连失败/pairing 失效 | 「配对文件失效，需重新生成」 | PC 端重新生成并导入 |
| 安装失败 | 显示 installd 返回的原始错误码 | 按错误码给出建议 |

所有 Engine 抛出统一错误类型（含原始底层错误），UI 层按上表转译。

## 9. 测试策略

- **单元测试（CI 可跑）**：ZIP 打包/解包、entitlements 注入结果校验、bplist 编解码、证书解析、错误码映射。纯逻辑部分在 macOS runner 上随构建执行。
- **真机验收（人工）**：证书申请、安装、DDI 挂载、定位模拟、恢复——私有协议链路无法仿真，每个里程碑由机主真机验收并在验证报告记录。
- **验收标准**：M1 = 在真机上完成一次「导入→签名→安装→启动」第三方 IPA；M2 = 地图选点后地图/天气类 App 显示新位置，恢复后回真值。

## 10. 构建与 CI

- 开发机（Windows）只写代码与配置；构建全部发生在 GitHub Actions。
- CI：`macos-15` runner + Xcode 构建（SwiftUI app + ldid C++ 交叉编译进 app）→ 产出未签名 IPA → artifact 上传；tag 推送时同时发 GitHub Release。
- 安装到手机：先经 M0 工具链（PC 端一次性）或 App 自身（功能就绪后）。
- 仓库：GitHub 私有仓库。

## 11. 里程碑

| 里程碑 | 内容 | 完成标志 |
| --- | --- | --- |
| **M0 spike（先行）** | Windows 上用 pymobiledevice3 + Sideloadly 验证四点：① 免费 Apple ID 签名安装链路 ② 开发者模式开启 + personalized DDI 挂载 ③ 定位模拟全局生效 ④ 恢复定位 | spike 验证报告（四项通过/失败与命令记录）+ pairing 文件；四项全部通过才进入 M1 |
| **M1 签名链** | ProvisioningEngine + SigningEngine + InstallEngine + 签名页 UI | 真机完成一次完整自签安装 |
| **M2 定位链** | LocationEngine + 定位页 UI | 真机选点模拟全局生效并可恢复 |
| **M3 打磨** | 7 天到期提醒、App 自续签、图标、错误引导完善 | 连续使用一周无阻碍 |

M0 是整个项目的可行性闸门：任何一项失败即停下重新评估路线，不盲目进入 App 开发。

## 12. 风险与缓解

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| iOS 小版本更新破坏私有协议 | 某条链路临时失效 | M0 报告记录协议版本；跟进 pymobiledevice3/SideStore 上游更新 |
| 免费 Apple ID 限频/风控 | 签名被拒 | 证书与 AppID 复用、请求节流 |
| DDI 个性化签名服务变更 | 定位功能失效 | 协议实现独立成模块，便于替换 |
| 自连 lockdownd 被封 | 安装功能失效 | 参照 SideStore 最新实现的替代通道 |
| 公共 anisette 服务器不可用 | 登录失败 | 设备端生成为主、公共服务器为备 |

## 13. 合规声明

本项目仅用于机主本人设备上的应用测试与隐私保护场景。自签分发与定位模拟可能违反某些第三方服务的使用条款，使用者在自身场景下的合规责任自负；本项目不内置任何针对特定第三方服务的绕过逻辑。

## 14. 已决事项记录

- 用途：自用（2026-11-04 用户确认）。
- 账号：免费 Apple ID（2026-11-04 用户确认）。
- 构建：GitHub Actions 云构建（2026-11-04 用户确认）。
- 定位形态：固定选点先行，轨迹/摇杆不做（2026-11-04 用户确认）。
- 路线：先 spike 验证再自建 App（2026-11-04 用户确认）。
- 设计 ①~⑥ 节：用户委托确认通过（2026-11-04「你自己决定合适的方式」）。
