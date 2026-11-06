# 接手状态（2026-11-05）

最新状态（2026-11-06）：0.1.4 源码 `077d712` 已通过 [CI](https://github.com/kevin9525/locsign/actions/runs/42140777649) 的 61 项 XCTest、4 项打包测试和未签名 iPhone 构建。用户在 iPhone 15 Pro Max / iOS 18.7.8 经 LocalDevVPN 复测后反馈“都正常了”，确认手机内配对 TLS 认证、AFC 和 installation_proxy 服务连接通过，`-9807 / self-signed certificate` 故障获真机复测确认。详见 [无 AKI 配对链修复记录](2026-11-06-pairing-chain-fix.md)。原配对文件可继续使用。用户无 P12/mobileprovision，下一步需接入免费 Apple ID 认证和证书/描述文件申请，再验证 IPA 实际上传、安装与启动；定位仍未完成。下文保留此前的历史状态。

## 工作区与版本

- 原工作区：CC GUI 的 `locsign`，基线提交 `025fedb`；未改动原工作区。
- 接手副本：本聊天 `work/locsign`，分支 `feat/nb-takeover`。
- 原生 worktree 建立后缺少写入授权，权限申请被会话中断；因此在已授权目录建立独立 Git 副本继续工作。

## 已实施，待 macOS 验证

- Zsign Swift 接口允许 nil completion，但 Objective-C 实现无条件调用回调；调用方改传非空闭包。参考上游固定提交 `c4ba9da4283031c07efa03bce42c4b8602d22e73`，不再依赖漂移分支。
- 签名产物与临时私钥工作目录分离，输出到应用缓存，替换/清除/模型销毁时清理旧产物；私钥工作目录由 defer 清理。IPA 导入复制在后台执行，保持文件访问授权直至复制完成。
- 从描述文件 Entitlements 读取 application-identifier，区分 AppIdentifierPrefix 与 TeamIdentifier；通配标识在签名时具体化。
- 过期、不匹配 Bundle ID、有未配置描述文件的扩展，明确返回错误。
- 回归测试改用真实 async 签名入口；样例证书为公开的合成材料，profile 有效期延至 2100，避免测试几天后失效。
- 中文签名页导入 IPA、P12/PEM、mobileprovision，签名后导出。没有 Apple ID 登录或自动安装的假成功路径。
- 只读 QueryType 设备连接探测，8 秒超时、取消、限长 plist 帧解析；成功只代表服务可达。
- CI 保留原始日志和 xcresult、设置超时、关闭并行测试；打包脚本采用可跨平台测试的 Python 实现，防止旧 ZIP 条目残留。

## 验证记录

- Python IPA 打包：4 项通过（布局、缺可执行文件拒绝、多 App 拒绝、重打包删除旧条目）。
- Swift 语法：tree-sitter 解析通过；只检查语法，不检查类型或 Apple SDK 可用性。
- project.yml 与 workflow YAML：解析通过。
- 合成 mobileprovision：OpenSSL CMS 签名并使用对应证书验证成功。并非 Apple 签发。
- XCTest / iOS 构建：未执行。本机没有 Xcode；GitHub Credential Manager 在沙箱中返回无法访问 wincredman，匿名请求私有仓库返回 404。
- 本次未做真机签名安装、手机内配对认证、设备端定位或后台维持验证。

## 下一步顺序

1. 推送新分支至已有 `kevin9525/locsign`，运行 GitHub Actions。先看 XCTest 数量与 xcresult，不能仅看汇总成功字样。
2. 用现有 Sideloadly 安装构建出的 unsigned IPA，测试签名导出和 QueryType 探测。
3. 接入 MIT 许可的 idevice（固定版本）完成配对认证、AFC/installation_proxy 与 CoreDeviceProxy/RSD。StikDebug 作为可行性参考，不直接拷贝 AGPL 代码进入未声明许可证的项目。
4. 完成设备端定位会话和后台策略，按切 App、锁屏 10 分钟、断网/重启、主动恢复逐项实测。
5. 免费 Apple ID 登录选择已有认证实现，核对 anisette 数据流与 2FA；保持 Apple 凭据只交给明确授权的目的地。

## NB 参考来源与边界

- https://nbtool8.com/ ：IPA 签名、虚拟定位、免 Wi-Fi，首次需电脑安装。
- https://nbtool8.com/help-center.html ：USB/驱动、解锁、信任电脑、开发者模式。
- https://github.com/SideStore/SideStore ：本地 VPN 与 minimuxer 安装路径。
- https://github.com/StikDebug/StikDebug ：iOS 17.4+ 设备端开发服务与 Location Simulator。
- https://github.com/jkcoxson/idevice ：MIT；AFC、安装服务、DDI、DVT、定位与用户态隧道。

NB 未公开内部源码，因此只对齐已公开行为，不声称复现了其私有实现。免 Wi-Fi 与后台长期维持仍需本机实测。

## 独立审查

按 executing-plans 要求完成一次独立代码审查。已处理：Combine 导入缺失、SwiftUI Section 构造方式、旧 IPA 产物累积、合成 profile 即将过期、IPA 导入阻塞主线程。Swift/XCTest 的 RED/GREEN 未执行，不能把本地静态检查替代为通过；Windows 打包测试已实际执行。

## 手机内安装链路续作（2026-11-05）

- 已接入配对 plist 导入、lockdownd TLS 会话、配对 TLS 身份、AFC IPA 上传、installation_proxy 进度和签名页的安装入口。
- AFC 暂存使用每次独立的 `/PublicStaging/LocSign-<UUID>/app.ipa`，先确保父目录和子目录存在，安装结束或失败时尝试清理文件与子目录。该布局参考 pymobiledevice3 的公开安装流程；LocSign 代码未复制其实现。
- 已增加配对导入时保留签名产物、AFC 建目录帧和畸形安装进度响应的 XCTest，并补充真实本地 TLS 分包/拒绝错误根证书、PEM/PKCS#8 导入和安装 UI 状态测试。Windows 没有 Xcode；已通过上述 macOS CI。真机配对/安装仍未验收。
- 本地 `git diff --check` 与 `python -m unittest discover -s Tests/BuildTools -v` 通过；Python 打包测试 4 项通过。它们不能替代 Swift 编译或设备验证。
