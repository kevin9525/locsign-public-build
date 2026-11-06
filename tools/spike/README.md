# M0 Spike 过程记录

> 本文件是 M0 spike 的逐步记录（环境事实 + 失败排查），最终结论见 `docs/spike/2026-11-M0-spike-report.md`。
> venv 位于 `tools/spike/.venv`；以下 `pymobiledevice3` 均指 `tools/spike/.venv/Scripts/pymobiledevice3`（Windows shell 状态不跨调用保留，用全路径）。

## 环境事实（Task 1）

- pymobiledevice3：**11.49.5**（pip show 验证；11.x 无 `--version` 选项）
- 设备：**iPhone11,6（iPhone XS Max）**，iOS **18.7.3**，ActivationState=Activated
- UDID：`REDACTED-DEVICE-UDID`（后四位 **002E**）
- 连接：USB（`pymobiledevice3 usbmux list` 返回 USB 直连条目）
- **pairing 文件**：`C:\Users\<user>\.pymobiledevice3\REDACTED-DEVICE-UDID.plist`（M1 InstallEngine 输入物）
- **开发者模式：已开启**（`pymobiledevice3 amfi developer-mode-status` → `true`）

## 关键发现：CLI 形态与文档差异（11.x）

- 开发者模式子命令在**顶层 `amfi` 组**：`reveal-developer-mode` / `enable-developer-mode` / `developer-mode-status`；旧文档的 `lockdown developer-mode` 已不存在。
- `lockdown info` 输出中**不含** `DeveloperModeStatus` 键，状态查询只能走 amfi 子命令。
- `pymobiledevice3.lockdown.create_lockdown_client` API 不存在（11.x 已移除，建议符为 `RemoteLockdownClient`）——写 App 时以源码为准。

## 失败与排查记录

1. `pymobiledevice3 --version` → `No such option: --version`（exit 2）。改用 `pip show pymobiledevice3`。
2. `Apple Mobile Device Service` 安装但 STOPPED，普通权限 `sc start` 被拒（错误 5）→ UAC 提权启动成功。
3. 服务启动后 `usbmux list` 仍返回 `[]`：服务是在设备已接入后才启动的，错过热插拔事件；Windows 侧 PnP 显示 Apple iPhone/Composite Device 均 OK → **重新插拔数据线后识别成功**。
4. 配对流程：`pymobiledevice3 lockdown pair` → 手机点「信任」→ 配对记录落盘（见上路径）。

## 命令备忘

```bash
tools/spike/.venv/Scripts/pymobiledevice3 usbmux list
tools/spike/.venv/Scripts/pymobiledevice3 lockdown info
tools/spike/.venv/Scripts/pymobiledevice3 lockdown pair
tools/spike/.venv/Scripts/pymobiledevice3 amfi developer-mode-status
```

## 闸门① 免费AppleID签名安装

- 工具: Sideloadly（版本未记录，用户 GUI 安装）
- 测试包: Feather v2.9.0（开源第三方应用，14,241,853 字节，github.com/claration/feather —— 仅作签名链路测试对象，非本项目产物）
- 2FA: 用户未明确记录（签名安装最终成功）
- 设备侧信任: 成功（App 可启动即隐含信任已完成）
- 启动: 成功（用户真机确认能进入主界面）
- 错误原文: 首次失败 `Get XcodeToken err GetAppToken err hsc=400 ec=-80046 au=em=This action cannot be completed at this time.`——根因：系统代理开启（ProxyEnable=1, 127.0.0.1:7890=FlClash），Apple 证书申请走机房代理 IP 触发风控；**关闭系统代理后重试即成功**
- 结论: **PASS**

> **M1 设计约束（由此闸门得出）**：ProvisioningEngine 对 Apple 的全部请求必须**直连**（绕过系统代理），代码层需强制 bypass 系统代理或检测代理状态并给出明确提示。

## 闸门② 开发者模式+DDI挂载

- 开发者模式开启方式: 已是开启状态（无需触发；预检 `amfi developer-mode-status` → true）
- DeveloperModeStatus: true
- mounter 实际命令行: `pymobiledevice3 mounter auto-mount`（11.49.5 子命令名为 auto-mount，无裸 mount/fetch-ddi；TSS 个性化签名请求向 Apple 在线发起并成功）
- 挂载结果: 成功——`DeveloperDiskImage mounted successfully`；`mounter list` 可见 Citrine cryptex（Variant: Public）
- 错误原文: ① 首跑默认命中另一台在线设备（UDID 00008130-…，目标机未插）`Device not found: usbmux has no device matching udid 00008130-…`；② 解锁前挂载被拒 `The device refused to receive the Personalized image: {'Error': 'DeviceLocked'}`——**解锁手机后立即成功**
- 结论: **PASS**

> **M2 设计约束（由此闸门得出）**：① LocationEngine 发起 DDI 挂载前必须确认/引导「屏幕已解锁」，锁屏态系统拒绝接收个性化镜像；② 多设备环境下需校验目标设备唯一性（usbmux 只有一台在线时才继续，否则要求用户指定）。

## 闸门③④ 定位模拟与恢复

- simulate-location 实际命令行: `pymobiledevice3 developer dvt simulate-location set 39.90923 116.397428`（纬度/经度为**位置参数**，非 --lat/--lng；iOS 17+ 自动走 no-root userspace tunnel；命令停在 "Press ENTER to exit" 等待 stdin）
- 三点验证: 地图=一致（多个存活窗口确认显示北京） 天气=未单独确认 Safari=未单独确认（用户未逐项观测，机制为 CoreLocation 全局级，以地图为代表证据）
- 持久性(Ctrl-C/会话结束后): **失效**——会话断开定位即自动还原（用户实测确认）
- 恢复: clear=有效（`simulate-location clear` rc=0——该 rc 为执行会话转述+用户确认，原始 stdout 未持久化；原始日志仅存一次失败尝试 sim-clear.log。会话结束自动还原为独立佐证） 重启=未测（clear 已生效，无需重启兜底）
- 错误原文: ① 后台运行的 set 会话两轮在验证窗口内死亡（运行环境会在用户消息到来时终止后台任务——改为前台保活方案）；② 三轮 `Device is not connected`（USB 链路不稳，重插恢复；建议换线/后置口）
- 结论: **PASS**

> **M2 设计约束（由此闸门得出）**：① 模拟定位**随会话失效**——App 必须常驻持有会话（后台保活）才能维持模拟，这是 LocationEngine 的核心设计点；② 恢复真实定位两条路都已验证：主动 `clear`（会话内）或结束会话；③ 命令形态为位置参数 + 会话保持语义，M2 移植到 Swift 时按 pymobiledevice3 源码的 DVT/tunnel 协议实现。
