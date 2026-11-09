# LocSign

iOS 18 签名与定位工具的开发中项目，参考 NB 助手的核心使用流程。

当前版本 **0.2.9 / build 15** 修复安装时的 `0xe8008017` 资源签名错误：描述文件在生成资源清单前写入，签名后只检查、不再补写文件。手机上的失败 IPA 已确认仅 `embedded.mobileprovision` 未进入签名清单，其余 77 项资源哈希匹配。固定版本 Zsign 以本地源码纳入一处条件补丁，详细证据见[资源签名修复](docs/spike/2026-11-09-signing-resource-seal.md)。更新后必须重新签名；旧的签名产物不会自动修复。

继续保留 0.2.8 的网络安装心跳：文件操作前完成首次应答，安装期间持续保活，结束时关闭连接；已知心跳失败阻止提交 Install。原 TLS 证书校验和服务顺序保持不变。0.2.8 真机重现已走通上传和提交安装，随后遇到上述资源校验错误；0.2.9 交付后，用户于 2026-11-09 确认 Feather 安装成功且能正常打开。对照证据见[安装心跳修复](docs/spike/2026-11-09-install-heartbeat.md)。

继续保留 0.2.6 的 C03 证书内容恢复、PEM/DER/Base64 支持、C01–C09 诊断、可选个人签名标识、Apple ID 登录、材料复用、手动导入和签名导出。申请结果不确定时保存私钥，重试只查询匹配证书，不重复提交 CSR；只有明确的申请拒绝才允许再次申请。查询不到匹配证书时会停止，不保证恢复成功。个人标识在同一团队与原 App 下固定，新标识作为独立应用安装。证书撤销必须确认精确列表；不会自动删除 profile 或修改 capability。详见[缺失证书内容恢复](docs/spike/2026-11-07-missing-certificate-content.md)。

自动申请当前接受无扩展/嵌套 App、未加密的单一 arm64 IPA；FAT 主程序、DER entitlement 与额外 capability 暂不支持。0.2.9 的 250 项 XCTest、4 项打包测试、模拟器/设备构建和 IPA 打包已通过[CI](https://github.com/kevin9525/locsign-public-build/actions/runs/42571719945)，最终 IPA 的版本、原应用标识、必需资源和 CRC 已核验。两条真实签名回归用例在修复前复现缺少描述文件资源项，修复后通过，包括主程序对资源清单的签名校验。用户于 2026-11-09 确认 Feather 安装成功且能正常打开，本次签名安装流程通过[真机验收](docs/apple-id-acceptance.md)；该结果不代表所有 IPA 均兼容。Apple ID 登录及配对已由用户确认成功；C03 恢复是否成功需按实际签名材料来源单独确认。全局定位仍未接入。

Anisette 默认地址为 `https://mac-ani.jkcoxson.com`。使用前需同意 UUID、ADI 握手消息/ADI blob 和来源 IP 披露；可换地址或关闭；已有材料可在重新校验后本机签名，无需访问提供方或 Apple。密码仅用于本次 Apple 登录，会话和私钥保存到本机专用 Keychain。覆盖更新保留资料；明确退出清除该账号资料和当前自动签名产物。

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

1. 用 Sideloadly 为未签名的 0.2.9 IPA 签名并安装；更新现有 LocSign 时使用原来的 Apple ID 和 Bundle ID。覆盖更新以保留材料，不先卸载或退出清除。旧版本生成的 IPA 须在新版重新签名，优先使用“使用本机有效材料签名”，并保持相同团队和个人签名标识。
2. 开启 LocalDevVPN，在 LocSign 的“连接”页面保留默认设备地址 `10.7.0.1`，点“检测连接”。其他隧道请填写实际设备 IP，不填写网址或域名。
3. 选择**这台手机**的电脑配对 plist，然后点“验证配对与安装服务”。已通过 USB 放入 LocSign 文档目录的文件可从“我的 iPhone → LocSign”选择。
4. 成功结果会显示配对身份认证、文件传输服务连接、安装服务连接均通过。此检查不上传 IPA、不执行安装，无需 P12、mobileprovision 或 Apple ID 登录。

配对文件含设备凭据，应仅保留在自己的电脑和手机。通过 Sideloadly 安装 LocSign 不会自动为 LocSign 提供可复用的签名证书。

### 有有效签名材料时

1. 签名：导入一个无扩展的 IPA、与其 Bundle ID 匹配且有效的 mobileprovision、对应的私钥/P12；完成签名后导出并再次解包确认产物存在。
2. 安装有效性：通过受支持安装工具安装并启动导出文件。界面“生成文件”不代表 iOS 已接受签名。
3. 连接与安装：配置可访问设备服务的本地 VPN/隧道后输入地址；先单独检测连接、验证配对与安装服务，再在签名页导入配对 plist 测试 AFC 上传和安装。服务连接正常不等于实际安装成功。0.2.9 交付后 Feather 的真机安装和启动已由用户确认；其他 IPA 仍需分别验证，优先使用本机有效材料并保持原个人签名标识。失败时记录完整步骤前缀及错误码。
4. 当前不做定位效果验收，因为设备端定位服务尚未接入。

详细接手记录：[docs/spike/2026-11-05-takeover-status.md](docs/spike/2026-11-05-takeover-status.md)。

本轮安装实现、CI 证据及真机步骤：[docs/spike/2026-11-05-install-validation.md](docs/spike/2026-11-05-install-validation.md)。

0.1.3 配对证书兼容修复与失败/成功测试证据：[docs/spike/2026-11-05-pairing-tls-subject-fix.md](docs/spike/2026-11-05-pairing-tls-subject-fix.md)。

0.1.4 真实证书对照、无 AKI 链构建修复和回归证据：[docs/spike/2026-11-06-pairing-chain-fix.md](docs/spike/2026-11-06-pairing-chain-fix.md)。

0.2.1 Feather 签名填充兼容修复和回归证据：[docs/spike/2026-11-07-feather-preflight-fix.md](docs/spike/2026-11-07-feather-preflight-fix.md)。

0.2.2 开发者服务错误诊断修复和复测步骤：[docs/spike/2026-11-07-developer-services-errors.md](docs/spike/2026-11-07-developer-services-errors.md)。

0.2.3 可选个人签名标识、注册错误分类和复测步骤：[docs/spike/2026-11-07-personal-signing-identifier.md](docs/spike/2026-11-07-personal-signing-identifier.md)。
