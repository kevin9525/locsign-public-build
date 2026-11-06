# LocSign M0 Spike 验证报告

日期：2026-11-04
执行人：机主（真机操作）；助手：Claude（命令执行与记录）
计划：`docs/superpowers/plans/2026-11-04-locsign-m0-spike.md`；过程记录：`tools/spike/README.md`

## 环境事实

- iPhone 型号：iPhone11,6（iPhone XS Max）；iOS：**18.7.3**（Build 22H217）；已激活
- pymobiledevice3：**11.49.5**（Windows venv，`tools/spike/.venv`）
- Sideloadly：版本未记录（用户 GUI 安装）
- 网络：FlClash 代理环境；**Apple 签名接口直连**（系统代理开启时会触发风控）
- pairing 文件：`C:\Users\<user>\.pymobiledevice3\REDACTED-DEVICE-UDID.plist`
- 开发者模式：开启（`amfi developer-mode-status` → true）

## 四闸门结论

| 闸门 | 内容 | 结论 | 关键证据 |
| --- | --- | --- | --- |
| ① | 免费AppleID签名安装 | **PASS** | Sideloadly 关系统代理后签名+安装成功，Feather 真机可启动（`apps list` 设备侧复核已装） |
| ② | 开发者模式+DDI挂载 | **PASS** | TSS 在线签名成功 → `DeveloperDiskImage mounted successfully`（Citrine cryptex） |
| ③ | 定位模拟全局生效 | **PASS**（限定：全局性为机制推断） | 会话存活期间地图显示北京（CoreLocation 全局级机制推断；天气/Safari 未逐项确认，M2 验收补验） |
| ④ | 恢复定位 | **PASS** | 会话结束自动还原（用户实测）；会话存活期 `clear` 主动还原（rc=0 为执行会话转述+用户确认，原始 stdout 未持久化，证据等级见 README） |

## spike 问题答案（M1/M2 设计输入）

1. **模拟定位在会话结束后是否持久**：**不持久**——会话断开定位立即还原。M2 的 App 必须**常驻持有会话**（后台保活）才能维持模拟。
2. **clear 是否有效，还是必须重启**：`clear` 有效（会话存活期间主动 clear，rc=0，真机确认还原）；无需重启兜底。
3. **simulate-location / mounter 的实测命令行**：
   - `pymobiledevice3 mounter auto-mount`（11.49.5 无裸 mount；TSS 个性化签名在线请求自动完成）
   - `pymobiledevice3 developer dvt simulate-location set <lat> <lng>`（**位置参数**；iOS 17+ 自动 no-root userspace tunnel；会话保持语义，停在 "Press ENTER"）
   - `pymobiledevice3 developer dvt simulate-location clear`
   - `pymobiledevice3 amfi developer-mode-status`（开发者模式状态在顶层 amfi 组）
4. **免费账号限制是否被触发、错误原文**：**未探测**（账号刚经历 -80046 风控，避免再触发；M1 开发期间观察）。实际遇到过的错误：`Get XcodeToken err hsc=400 ec=-80046`（系统代理致机房 IP 风控——**关代理直连后消失**）。
5. **模拟是否全局一致（三点验证）**：地图确认全局生效（CoreLocation 级模拟）；天气/Safari 未逐项确认——M2 验收时补验。
6. **M1 带入待验证项**：① 2FA 验证码到达方式与流程（ProvisioningEngine 登录 UX 输入）；② 免费 Apple ID 3 App/7 天限制的实测错误原文（节流设计输入）。

## 失败与绕行记录

1. `--version` 不存在 → 用 `pip show`（11.x 移除该选项）。
2. Apple Mobile Device Service 停止且普通权限无法启动 → UAC 提权启动；服务运行中设备仍需重插一次才被 usbmux 枚举。
3. `lockdown.developer-mode` 子命令已迁移至顶层 `amfi` 组；`lockdown info` 无 DeveloperModeStatus 键。
4. 挂载阶段两轮失败：目标机离线时 auto-mount 默认命中另一台设备（UDID 00008130-…）；锁屏态被拒（`{'Error': 'DeviceLocked'}`）——**解锁后立即成功**。
5. 定位模拟两轮验证窗口内会话死亡：运行环境在用户消息到来时终止后台任务 → 改为前台保活（python 持有 stdin）方案。
6. USB 链路三轮掉线（`Device is not connected`）→ 重插恢复；建议换数据线/后置 USB 口。
7. pymobiledevice3 11.49.5 无全局 `--udid` 选项；多设备场景需人工确认唯一性。

## 总结论

**GO**（进入 M1 签名链 App 开发）

四条链路在 iOS 18.7.3 真机全部走通：免费 Apple ID 设备端签名安装可行（须直连 Apple）；开发者模式+个性化 DDI 挂载可行（须解锁态）；全局定位模拟可行（会话保活语义明确，恢复路径明确；全局性以地图为代表证据，天气/Safari 在 M2 验收补验）。关键设计输入已全部落档：M1 需直连约束 + 节流设计，M2 需会话常驻 + 解锁前置 + clear 恢复。
