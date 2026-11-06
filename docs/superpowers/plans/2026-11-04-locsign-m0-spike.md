# LocSign M0 Spike 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在机主真机（iOS 18.x）上用现成 PC 工具验证「免费 Apple ID 签名安装、开发者模式+DDI 挂载、定位模拟、恢复定位」四条链路，产出 spike 报告作为进入 M1 的 GO/NO-GO 闸门。

**Architecture:** 纯 PC 端验证，不写 App 代码。pymobiledevice3（CLI）负责设备通信、配对、开发者模式、DDI 挂载与定位模拟；Sideloadly（GUI）负责免费 Apple ID 的签名+安装。所有发现与记录落仓库。

**Tech Stack:** Python 3.11+（venv）、pymobiledevice3 最新版、Sideloadly、iTunes（apple.com 64 位版，提供 USB 驱动）、Git Bash（Windows）。

**Spec:** `docs/superpowers/specs/2026-11-04-locsign-ios18-design.md`（§11 里程碑 M0）

## Global Constraints

- 设备：iPhone，iOS 17.0–18.x，不越狱；操作期间保持解锁，弹窗一律点「信任」并输入锁屏密码。
- 账号：仅免费 Apple ID（本项目不注册付费账号）。
- 测试坐标固定：纬度 `39.90923` / 经度 `116.397428`。
- 任何命令失败：先把**原始报错全文**记入 `tools/spike/README.md` 再排查；四项闸门未全部通过不得宣布 M0 通过。
- 产物路径：过程记录写 `tools/spike/README.md`，最终报告写 `docs/spike/2026-11-M0-spike-report.md`；随做随 commit。
- 网络：PyPI 直连慢时加清华镜像 `-i https://pypi.tuna.tsinghua.edu.cn/simple`（用户有 FlClash 代理，TUN 模式下通常直连即可）。
- spike 脚本与文档属一次性验证工具，按 spec §10 允许存在于仓库，不作为 App 代码。

## Review Focus

1. **Microsoft Store 版 iTunes 不含第三方可用的 usbmux 驱动** —— 期望 `pymobiledevice3 usbmux list` 能列出设备 UDID；列不出即换 apple.com 版 iTunes 重装。测试：Task 1 Step 4。
2. **Apple ID 登录被 2FA 打断** —— 期望按提示输入 6 位验证码后流程继续完成；记录验证码到达方式（信任设备弹窗/短信）。测试：Task 2 Step 5。
3. **免费 Apple ID 的 3 App / 7 天限制** —— 期望超限时报错明确（如 `maximum number of app IDs`）而非静默失败；记录错误原文。测试：Task 2 Step 8。
4. **iOS 18.x 上 simulate-location 的子命令形态与文档不一致** —— 期望以 `--help` 实测为准，记录准确可用的完整命令行。测试：Task 4 Step 1。
5. **模拟定位非全局（仅部分 App 生效）** —— 期望地图 App、天气 App、Safari 网页三处一致显示测试坐标。测试：Task 4 Step 4。

---

### Task 1: spike 环境与设备配对

**Files:**
- Create: `tools/spike/README.md`
- Create: `.gitignore`

**Interfaces:**
- Consumes: 无（首个任务）
- Produces: 可用的 pymobiledevice3 环境（venv 路径 `tools/spike/.venv`）、设备 UDID 与 iOS 版本记录、pairing 文件路径（Task 3/4 依赖此配对；M1 InstallEngine 依赖 pairing 文件本身）

- [ ] **Step 1: 创建 Python 虚拟环境并安装 pymobiledevice3**

```bash
cd /c/Users/<user>/.ccgui/workspace/locsign
python -m venv tools/spike/.venv
source tools/spike/.venv/Scripts/activate
pip install -U pymobiledevice3
```

预期：pip 安装成功无报错。若 PyPI 超时，重试并追加 `-i https://pypi.tuna.tsinghua.edu.cn/simple`。

- [ ] **Step 2: 验证 pymobiledevice3 可用**

```bash
pymobiledevice3 --version
```

预期：打印版本号（记录到 README）。

- [ ] **Step 3: 写 `.gitignore` 排除 venv**

```gitignore
.venv/
__pycache__/
*.pyc
```

写入仓库根目录 `.gitignore`（已存在则追加这三行）。

- [ ] **Step 4: 验证 USB 驱动与设备识别（Review Focus 1 的测试）**

前置：iPhone 用数据线连接电脑，解锁。iTunes 必须是从 https://www.apple.com.cn/itunes/download/ 安装的 64 位版（**不是** Microsoft Store 版）；已装 Store 版的先卸载再装 apple.com 版。

```bash
pymobiledevice3 usbmux list
```

预期：输出 JSON 数组，含设备 `udid`、`DeviceName`。若空数组/报错：检查 `AppleMobileDeviceService` 服务是否运行（`services.msc`），重插数据线换 USB 口，重装 apple.com 版 iTunes。把最终成功/失败状态记入 README。

- [ ] **Step 5: 读取设备信息**

```bash
pymobiledevice3 lockdown info
```

预期：输出设备信息 JSON。记录 `ProductType`、`ProductVersion`、`ApplicationType` 无关字段忽略。`ProductVersion` 必须 ≥ 17.0，否则停下向用户确认设备不符 spec。

- [ ] **Step 6: 配对（生成 pairing 文件）**

```bash
pymobiledevice3 lockdown pair
```

预期：手机弹「信任此电脑」→ 点信任并输入锁屏密码 → 命令输出配对成功。配对记录默认落盘于 `~/.pymobiledevice3/`（Windows 为 `C:\Users\<user>\.pymobiledevice3\`）。用 `ls ~/.pymobiledevice3/` 确认存在 `<UDID>.plist`，把**绝对路径**记入 README——这是 M1 InstallEngine 的输入物。

- [ ] **Step 7: 创建 `tools/spike/README.md` 并提交**

内容：环境事实（pymobiledevice3 版本、iOS 版本、UDID 后四位）、pairing 文件路径、失败记录（若有）。然后：

```bash
git add .gitignore tools/spike/README.md
git commit -m "spike: 环境就绪，设备已配对"
```

---

### Task 2: 免费 Apple ID 签名安装链（闸门 ①）

**Files:**
- Modify: `tools/spike/README.md`（追加本闸门记录）

**Interfaces:**
- Consumes: Task 1 的设备连接与配对
- Produces: 闸门 ① 结论（免费账号签名安装可行/不可行 + 错误原文）；手机上可启动的测试 App

- [ ] **Step 1: 下载测试 IPA**

浏览器打开 https://github.com/khcrysalis/Feather/releases ，下载最新版的 `Feather.ipa`（约 10–20 MB 的开源签名器，正好用作测试对象），存到 `tools/spike/downloads/Feather.ipa`（目录自行创建，`.gitignore` 追加一行 `tools/spike/downloads/`）。备选：任意 GitHub 开源应用的 IPA 均可，记录实际用的包名与版本。

- [ ] **Step 2: 安装 Sideloadly**

浏览器打开 https://sideloadly.io ，下载 Windows 版并安装。安装过程若提示装 iTunes/驱动组件，允许其完成。

- [ ] **Step 3: Sideloadly 签名并安装（用户手动 GUI 操作，助手逐步引导）**

1. 手机连电脑并解锁。
2. 打开 Sideloadly：把 `Feather.ipa` 拖入 IPA 框。
3. Apple ID 框输入**免费 Apple ID** 邮箱；勾选「Normal Installation」。
4. 点 Start。期间手机保持解锁。

预期：Sideloadly 显示签名与传输进度，结束提示成功，手机桌面出现 Feather 图标。任何报错截图/原文记录进 README。

- [ ] **Step 4: 记录 2FA 处理（Review Focus 2 的测试）**

若 Sideloadly 弹出 6 位验证码输入框：在 iPhone 弹窗（或短信）取得验证码填入，流程应继续完成。记录验证码到达方式与是否一次通过。

- [ ] **Step 5: 手机端信任开发者证书（用户手动）**

手机：设置 → 通用 → VPN与设备管理 → 选中刚出现的 Apple ID 开发者条目 → 点「信任」。预期：信任后 Feather 可正常打开不再弹「不受信任的开发者」。

- [ ] **Step 6: 启动 Feather 验证（闸门 ① 的设备侧证据）**

打开 Feather，预期进入其主界面（它本身是签名工具，能看到界面即证明签名安装的 App 可运行）。记录启动是否成功。

- [ ] **Step 7: 把闸门 ① 结论写入 README**

模板（逐字使用，值按实际填）：

```
## 闸门① 免费AppleID签名安装
- 工具: Sideloadly <版本号>
- 测试包: Feather <版本号>
- 2FA: <到达方式/是否顺利>
- 设备侧信任: <成功/失败>
- 启动: <成功/失败>
- 错误原文: <无/原文>
- 结论: PASS / FAIL
```

- [ ] **Step 8: 限制行为探测（Review Focus 3 的测试，可选但尽量做）**

在 Sideloadly 用同一 Apple ID 再签一个不同的开源 IPA（步骤同 Step 3）。预期：免费账号最多 3 个自签 App，第 4 个会被 Apple 拒绝并报错。记录是否触发限制及错误原文（触发与否都算有效数据，影响 M1 的节流设计）。不做不阻塞闸门结论，但要在 README 标注「未探测」。

- [ ] **Step 9: 提交**

```bash
git add tools/spike/README.md .gitignore
git commit -m "spike: 闸门① 免费AppleID签名安装结论"
```

---

### Task 3: 开发者模式 + DDI 挂载（闸门 ②）

**Files:**
- Modify: `tools/spike/README.md`（追加本闸门记录）

**Interfaces:**
- Consumes: Task 1 的配对；闸门 ② 通过是 Task 4 的前提
- Produces: 闸门 ② 结论；已挂载的 Developer Disk Image（Task 4 定位模拟依赖）

- [ ] **Step 1: 触发并开启开发者模式（用户手动为主）**

```bash
pymobiledevice3 lockdown developer-mode --help
```

先看该子命令真实用法并记录。若支持 `enable`（会触发设备弹窗/重启提示）则用它；同时手动路径兜底：手机 设置 → 隐私与安全性 → 开发者模式 → 打开 → 按提示重启手机。若设置里没有「开发者模式」入口，先执行上面 help 中可行的触发命令再重查设置。

- [ ] **Step 2: 重启后验证开发者模式状态**

```bash
pymobiledevice3 lockdown info | grep -i developer
```

预期：`DeveloperModeStatus` 为 `1`（或 true）。记录实际输出行。注意 macOS 的 grep 语法在 Git Bash 下相同；无输出时直接看 `lockdown info` 全文人工找该键。

- [ ] **Step 3: 探明 mounter 子命令并挂载 DDI**

```bash
pymobiledevice3 mounter --help
pymobiledevice3 mounter mount --help
```

记录当前版本的子命令与参数名（不同版本可能是 `fetch-ddi` / `mount` / `auto-mount`）。执行挂载（典型形态）：

```bash
pymobiledevice3 mounter mount
```

若报缺镜像，先执行镜像获取（以 help 实测为准）：

```bash
pymobiledevice3 mounter fetch-ddi
```

预期：挂载成功（输出 mounted/success 类字样，手机无需重启）。失败时记录原文并检查：开发者模式已开、设备已解锁、pymobiledevice3 已 `pip install -U` 到最新。

- [ ] **Step 4: 把闸门 ② 结论写入 README**

模板（逐字使用）：

```
## 闸门② 开发者模式+DDI挂载
- 开发者模式开启方式: <设置手动/命令触发>
- DeveloperModeStatus: <实际值>
- mounter 实际命令行: <完整命令>
- 挂载结果: <成功/失败>
- 错误原文: <无/原文>
- 结论: PASS / FAIL
```

- [ ] **Step 5: 提交**

```bash
git add tools/spike/README.md
git commit -m "spike: 闸门② 开发者模式与DDI挂载结论"
```

---

### Task 4: 定位模拟与恢复（闸门 ③④）

**Files:**
- Modify: `tools/spike/README.md`（追加本闸门记录）

**Interfaces:**
- Consumes: Task 3 已挂载 DDI
- Produces: 闸门 ③④ 结论；关键 spike 问题答案（模拟持久性、clear 有效性）——直接决定 M2 LocationEngine 的会话设计

- [ ] **Step 1: 探明 simulate-location 实际命令形态（Review Focus 4 的测试）**

```bash
pymobiledevice3 developer dvt simulate-location --help
```

记录当前版本的真实子命令（典型为 `set` 与 `clear`）与参数名。**后续步骤以此 help 实测为准**，不要照抄本文档的示例形态。

- [ ] **Step 2: 设置模拟定位**

按 Step 1 探明的形态执行（典型形态）：

```bash
pymobiledevice3 developer dvt simulate-location set --lat 39.90923 --lng 116.397428
```

预期：命令运行并保持在前台（部分版本需要保持会话）。**此终端先不要关**。

- [ ] **Step 3: 三点全局验证（Review Focus 5 的测试，用户手动）**

手机依次打开并记录读数：
1. 自带「地图」App —— 定位蓝点是否在天安门附近；
2. 自带「天气」App —— 城市是否变为北京；
3. Safari 打开 https://amap.com —— 网页定位是否为测试点。
预期：三处一致。任何一处不一致都记入 README（这是 M2 设计的关键输入）。

- [ ] **Step 4: 持久性观察（spike 关键问题）**

在 Step 3 验证后按 `Ctrl-C` 结束命令，等 30 秒再开地图看定位。记录：模拟是否仍然生效（是/否/降级为真实位置）。此答案决定 M2 中 App 是否需要后台保活会话。

- [ ] **Step 5: 恢复真实定位（闸门 ④）**

按 Step 1 探明的形态执行恢复（典型形态）：

```bash
pymobiledevice3 developer dvt simulate-location clear
```

预期：地图 App 定位回到真实位置。若 clear 无效，兜底验证重启手机后是否恢复真实定位，并把「clear 是否有效/是否必须重启」记入 README（决定 M2 恢复按钮的实现策略）。

- [ ] **Step 6: 把闸门 ③④ 结论写入 README**

模板（逐字使用）：

```
## 闸门③④ 定位模拟与恢复
- simulate-location 实际命令行: <完整命令>
- 三点验证: 地图<一致/不一致> 天气<一致/不一致> Safari<一致/不一致>
- 持久性(Ctrl-C后): <仍生效/失效/降级>
- 恢复: clear<有效/无效> 重启<有效/未测>
- 错误原文: <无/原文>
- 结论: PASS / FAIL
```

- [ ] **Step 7: 提交**

```bash
git add tools/spike/README.md
git commit -m "spike: 闸门③④ 定位模拟与恢复结论"
```

---

### Task 5: spike 报告与 GO/NO-GO

**Files:**
- Create: `docs/spike/2026-11-M0-spike-report.md`

**Interfaces:**
- Consumes: Task 1–4 的 README 记录
- Produces: M0 正式报告（M1 计划的输入与闸门）

- [ ] **Step 1: 写报告（按以下模板逐节填写，不留空）**

```markdown
# LocSign M0 Spike 验证报告

日期：<YYYY-MM-DD>
执行人：<名字>；助手：<Claude>

## 环境事实
- iPhone 型号：<ProductType>；iOS：<ProductVersion>
- pymobiledevice3：<版本>
- Sideloadly：<版本>
- 网络：<直连/代理/镜像>
- pairing 文件：<绝对路径>

## 四闸门结论
| 闸门 | 内容 | 结论 | 关键证据 |
| --- | --- | --- | --- |
| ① | 免费AppleID签名安装 | PASS/FAIL | <一句话> |
| ② | 开发者模式+DDI挂载 | PASS/FAIL | <一句话> |
| ③ | 定位模拟全局生效 | PASS/FAIL | <一句话> |
| ④ | 恢复定位 | PASS/FAIL | <一句话> |

## spike 问题答案（M1/M2 设计输入）
1. 模拟定位在会话结束后是否持久：<答案>
2. clear 是否有效，还是必须重启：<答案>
3. simulate-location / mounter 的实测命令行：<答案>
4. 免费账号限制是否被触发、错误原文：<答案/未探测>
5. 模拟是否全局一致（三点验证）：<答案>

## 失败与绕行记录
<逐条列出过程中所有原始报错与解法；无则写「无」>

## 总结论
GO / NO-GO（进入 M1 签名链 App 开发）
<一句话理由>
```

- [ ] **Step 2: 向用户宣读报告结论并确认**

四闸门全 PASS → 结论 GO；任何 FAIL → 结论 NO-GO 并停下与用户重新评估路线（按 spec §11，闸门语义不允许带病通过）。

- [ ] **Step 3: 提交报告**

```bash
mkdir -p docs/spike
git add docs/spike/2026-11-M0-spike-report.md tools/spike/README.md
git commit -m "spike: M0 验证报告与 GO/NO-GO 结论"
```
