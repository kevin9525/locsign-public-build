# 2026-11-22 App 扩展支持（带 PlugIns 的 IPA）

目标版本：0.4.11（30），与同日的 App 图标一起交付。此前 Apple ID 自动申请只接受无扩展的 App，带小组件、分享、通知等扩展的 IPA 在预检阶段就被拒绝。

## 范围

- 支持：主 App 的 `PlugIns/*.appex`（一层），每个扩展满足与主程序相同的规则：未加密、单一 arm64、仅基础权限。
- 不支持（预检明确拒绝）：Watch App 等嵌套 `.app`、扩展内部的 `PlugIns`、ExtensionKit 的 `Extensions/*.appex`、标识不在主 App 命名空间内的扩展、重复标识、超过 9 个扩展。
- 手动证书/描述文件签名仍不支持扩展：单个描述文件无法为扩展提供独立的精确 App ID。

## 设计

1. **预检**（`ProvisioningIPAPreflight`）：返回 `ProvisioningApp.extensions`。扩展的 `CFBundleIdentifier` 必须以 `<主 App 标识>.` 开头，`CFBundlePackageType` 为 `XPC!`。上限 9 个：免费账号每 7 天最多注册 10 个 App ID。
2. **标识重定向**（`ProvisioningSigningIdentifier.extensionIdentifier`）：选用个人签名标识时，扩展保留自身后缀，挂到新标识下（`a.b.widget` → `x.y.widget`），满足 iOS 对扩展前缀的要求。
3. **申请**（`DeveloperServicesProvisioner`）：
   - 所有扩展的现有 App ID 与主 App ID 一样，在任何远端修改前先读取并检查权限；不兼容时直接停止，不做任何修改。
   - 之后依次：注册设备（如需）→ 创建主 App ID → 创建各扩展 App ID → 证书（复用/申请逻辑不变）→ 主 App 描述文件 → 各扩展描述文件。
   - 每个扩展的描述文件复用、创建、409 冲突重查规则与主 App 完全相同，都绑定同一证书与设备。
   - 不删除描述文件、不修改 capability、不撤销证书（撤销仍需用户确认）。
4. **材料**（`ProvisioningMaterial.extensionProfiles`，可选字段，旧数据可正常解码）：`profileExpiry` 取主 App 与全部扩展中最早的到期时间。因此续签时间、"有效期必须延长"的判断，以及 App 列表显示的到期日，都以最先到期的那个为准。
5. **引擎复核**（`ProvisioningEngineLive`）：新申请和缓存复用时，逐个扩展按 CMS/团队/设备/证书/私钥规则重新验证；扩展集合必须与 IPA 一一对应，否则缓存视为不可用，新申请则报错。
6. **签名**（`SigningEngine` + 本地 Zsign 补丁）：
   - 签名前改写各扩展 `Info.plist` 的标识。
   - 每个扩展必须配到精确匹配的描述文件，不接受通配。
   - 调用新的 `Zsign.sign(appPath:provisionPaths:...)`；签名后逐个核对每个 bundle 内嵌的描述文件。
   - Zsign 上游多描述文件路径有两个问题：嵌套 bundle 的描述文件在生成 CodeResources 之后才写入，与 0.2.9 修过的 `0xe8008017` 同类；匹配用后缀，可能配错。已改为先按精确 application-identifier 选定描述文件并写入，再封资源；App/扩展没有匹配的描述文件时直接失败。详见 `Vendor/zsign/LOCSIGN.md` 与 `upstream.patch`。

## 测试（新增，待 CI 执行）

- `AppExtensionProvisioningTests`：
  - 预检：接受与 10 类拒绝情形、数量上限；
  - 标识重定向；
  - 多 App ID 申请顺序与 mutation 记录；
  - 复用已有描述文件时零 mutation；
  - 不兼容扩展 App ID 零 mutation；
  - Apple 返回错配描述文件时拒绝；
  - 旧材料解码。
- `IPAPackerTests`：
  - 真实 Zsign 签名带扩展的 IPA（含标识重定向），校验扩展与主 App 各自的描述文件字节、资源封签、CodeDirectory 对 CodeResources 的封签、扩展权限声明；父 bundle 封签需覆盖扩展描述文件；
  - 缺少扩展描述文件、用主 App 描述文件冒充扩展、手动签名带扩展三种情况均被拒绝。
- 新 fixture `profile-extension.mobileprovision`：由 `.ci/generate-profile-compatibility-fixtures.py` 用仓库内公开测试密钥生成，不含真实材料。

## 未验证

- Windows 本地无 Xcode：Swift/ObjC++ 代码未编译，XCTest 未运行，全部依赖 CI。
- 真机：Apple 是否接受扩展 App ID 的名称（使用扩展显示名）、扩展安装后能否启用（如在主屏添加小组件），都需在手机上验收。建议先用只带 1 个扩展的 IPA 测试，免得占用过多每周 App ID 额度。
