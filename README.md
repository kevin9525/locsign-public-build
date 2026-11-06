# LocSign

iOS 18 签名与定位工具的开发中项目，参考 NB 助手的核心使用流程。

当前版本 **0.1.4 验证版源码** 包含：已有 P12/PEM + 描述文件的 IPA 签名导出；无需签名证书的设备连接、配对身份及安装服务检查；以及 AFC 上传和 installation_proxy 安装链路的试验实现。0.1.4 修复无 AKI 的 Apple 配对证书被误判为自签名（`-9807`）的问题；提交 `077d712` 已通过 macOS CI 的 61 项 XCTest、4 项 Python 打包测试和未签名 iPhone 构建（[运行记录](https://github.com/kevin9525/locsign/actions/runs/42140777649)）。2026-11-06，用户在 iPhone 15 Pro Max / iOS 18.7.8 上经 LocalDevVPN 复测后反馈“都正常了”，确认配对认证、文件传输服务和安装服务连接通过。IPA 实际上传、安装与启动仍待验收，免费 Apple ID 登录与设备端全局定位仍未完成。

## 构建

需要 macOS、Xcode、XcodeGen。GitHub Actions 自动执行模拟器测试、设备构建并上传 `LocSign-ipa` 和 `LocSign-diagnostics`。

```sh
brew install xcodegen
xcodegen generate
xcodebuild test -project LocSign.xcodeproj -scheme LocSign \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -parallel-testing-enabled NO -resultBundlePath build/TestResults.xcresult \
  -derivedDataPath build
xcodebuild build -project LocSign.xcodeproj -scheme LocSign \
  -sdk iphoneos -configuration Release CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO -derivedDataPath build
python3 .ci/make-ipa.py
```

生成的是未签名 IPA，需要使用自己的 Apple ID 经 Sideloadly 等工具安装，不能直接点击安装。

## 本地辅助测试

```sh
python -m unittest discover -s Tests/BuildTools -v
```

测试打包逻辑，与 XCTest、真实安装验收是不同层次。

## 设备验收

### 没有签名证书时

1. 用 Sideloadly 为未签名的 0.1.4 IPA 签名并安装；更新现有 LocSign 时使用原来的 Apple ID 和 Bundle ID。
2. 开启 LocalDevVPN，在 LocSign 的“连接”页面保留默认设备地址 `10.7.0.1`，点“检测连接”。其他隧道请填写实际设备 IP，不填写网址或域名。
3. 选择**这台手机**的电脑配对 plist，然后点“验证配对与安装服务”。已通过 USB 放入 LocSign 文档目录的文件可从“我的 iPhone → LocSign”选择。
4. 成功结果会显示配对身份认证、文件传输服务连接、安装服务连接均通过。此检查不上传 IPA、不执行安装，无需 P12、mobileprovision 或 Apple ID 登录。

配对文件含设备凭据，应仅保留在自己的电脑和手机。通过 Sideloadly 安装 LocSign 不会自动为 LocSign 提供可复用的签名证书。

### 有有效签名材料时

1. 签名：导入一个无扩展的 IPA、与其 Bundle ID 匹配且有效的 mobileprovision、对应的私钥/P12；完成签名后导出并再次解包确认产物存在。
2. 安装有效性：通过受支持安装工具安装并启动导出文件。界面“生成文件”不代表 iOS 已接受签名。
3. 连接与安装：配置可访问设备服务的本地 VPN/隧道后输入地址；先单独检测连接、验证配对与安装服务，再在签名页导入配对 plist 测试 AFC 上传和安装。QueryType 成功不等于配对认证通过；服务连接正常也不等于实际安装成功。CI 已验证本地 TLS 传输和协议/UI 测试，AFC 上传及安装接受结果仍需真机完整验收。
4. 当前不做定位效果验收，因为设备端定位服务尚未接入。

详细接手记录：[docs/spike/2026-11-05-takeover-status.md](docs/spike/2026-11-05-takeover-status.md)。

本轮安装实现、CI 证据及真机步骤：[docs/spike/2026-11-05-install-validation.md](docs/spike/2026-11-05-install-validation.md)。

0.1.3 配对证书兼容修复与失败/成功测试证据：[docs/spike/2026-11-05-pairing-tls-subject-fix.md](docs/spike/2026-11-05-pairing-tls-subject-fix.md)。

0.1.4 真实证书对照、无 AKI 链构建修复和回归证据：[docs/spike/2026-11-06-pairing-chain-fix.md](docs/spike/2026-11-06-pairing-chain-fix.md)。
