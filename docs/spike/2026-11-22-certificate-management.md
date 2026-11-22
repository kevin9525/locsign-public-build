# 2026-11-22 Apple ID 证书管理（参考 NB 全能助手）

目标版本：0.4.12（31）。对照 NB 全能助手的"Apple ID 证书管理"：此前 LocSign 只在开发证书数量达上限时才弹出撤销确认，没有地方查看账号下有哪些证书、App ID、描述文件和设备，也看不到免费账号本周还能注册几个 App ID。

## 入口

- App 页新增"Apple ID → 证书与 App ID 管理"。
- 安装页"Apple ID 与签名设置"的"Apple ID 与团队"中同样可进入。
- 需要已登录且未过期的 Apple ID、已选团队、已确认 Anisette 提供方；安装、续签、登录进行中时入口禁用。

## 页面内容

1. **App ID 额度（免费账号）**：App ID 总数、近 7 天已用（估算）/ 10、剩余（估算）。Apple 不提供 App ID 的注册时间，估算口径是"7 天内新建过描述文件的 App ID"，页面明确标注仅供参考。
2. **开发证书**：名称、序列号、到期时间；LocSign 本机保存的 pending 或 active 材料所用证书标"LocSign 使用中"。每张证书可单独撤销。
3. **App ID**：名称、标识、描述文件数量与最晚到期时间（只读）。
4. **已注册设备**：名称、型号、是否停用；UDID 只显示末 6 位。

## 撤销流程（`DeveloperAccountManager.revoke`）

1. 用户在确认框中确认（LocSign 使用中的证书有单独的更强提示）。
2. 重新读取 Apple 证书列表；目标证书的 ID、序列号、名称、到期时间必须完全一致，否则停止，提示"未撤销任何证书"。
3. 先通过受保护的本地存储失效本机材料（pending 证书清空，active 若匹配则删除），再请求 Apple 撤销。与 0.2.x 证书数量上限处理的顺序相同：即使撤销响应丢失，本机也不会再复用该证书。
4. 无论成功或失败都重新读取一次列表并显示。

## 不做的事

- 不删除 App ID 或描述文件，不停用/删除设备，不修改 capability。删除 App ID 也不会退回免费账号的每周额度。
- 页面上的所有 Apple 请求都经过同一个 `ProvisioningEngineLive`：开始时会中止同一引擎上正在进行的其他请求（与 `cachedMaterial` 一致），因此 UI 在安装/续签/登录时禁用入口。

## 代码

- `Provisioning/DeveloperAccountOverview.swift`：概览数据类型、额度估算、`DeveloperAccountManager`；`DeveloperServicesGateway` 新增 3 个只读方法，带默认实现（直接失败），旧测试替身无需修改。
- `XKitDeveloperServicesGateway`：`GET /v1/bundleIds`、`GET /v1/bundleIds/{id}/profiles`（只取元数据，不保存描述文件内容）、`GET /v1/devices`。新增步骤名"查询应用标识列表"。
- `ProvisioningEngine` / `ProvisioningBackend`：新增 `accountOverview`、`revokeCertificate`，同样带默认实现。
- `Features/Account/DeveloperAccountModel.swift`、`DeveloperAccountView.swift`；`AppsView`、`AppleIDProvisioningSheet` 增加入口。

## 测试（新增，待 CI 执行）

`DeveloperAccountManagerTests`：
- 概览排序、按 App ID 归组描述文件、标记本机使用中的证书、读取全程零修改；
- 额度估算的 7 天严格边界、无创建时间不计入、剩余不为负；
- 撤销顺序：重读列表 → 失效本机材料 → 撤销；
- 证书序列号变化或已不存在时零修改；重读后被取消时零修改；本机失效失败时不发撤销请求；
- 网关默认实现直接失败；UDID 掩码；"列表已变化"提示文案。

## 未验证

- Windows 本地无 Xcode：Swift 未编译，XCTest 未运行，依赖 CI。网关新增的 3 个请求没有 HTTP 层测试（现有 `DeveloperAPIFixture` 未覆盖这些路径），字段取值依据 `Vendor/xtool` 生成的 `Types.swift`。
- 真机：免费账号下 `bundleIds` / `profiles` 列表是否返回完整字段（尤其 `createdDate`），以及撤销后列表刷新是否立即反映，需要在手机上核对。建议先撤销一张已过期或不再使用的证书。
