# LocSign

iOS 18 签名与定位工具的开发中项目，参考 NB 助手的核心使用流程。

**0.4.0 / build 19（验证中）** 增加 App 管理、到期前自动续签和固定点虚拟定位。新版安装会保留受保护的原 IPA；已安装 App 可从设备读取，旧版安装的 App 需选择原 IPA 再安装一次才能纳入续签管理。续签沿用原账号、团队、设备和签名标识，必须取得更晚到期的有效材料，只有设备确认安装完成才更新有效期。

自动续签默认提前 48 小时，失败后至少间隔 6 小时重试；系统安排后台机会，打开 App 时补做。可逐个或全部关闭，并开启失败通知。登录失效、证书撤销确认或设备变更需用户处理。LocSign 自身只允许手动续签，替换后需重新启动核对新描述文件；不会在后台自动退出自己。

定位支持地图选点、地址搜索、经纬度输入、应用和恢复。需要开发者模式、匹配的配对文件和 LocalDevVPN；首次准备向 Apple 请求开发者镜像个性化。使用固定版本 idevice 的 CoreDevice/RSD/DVT 接口，并保持定位连接；系统挂起后不能保证持续生效。该版本的构建、测试与真机验收结果在完成后记录，不能把地图上的标记视为设备已修改位置。

上一稳定版本 **0.3.2 / build 18** 修复创建描述文件始终使用固定名称的问题：仍优先复用有效材料，确实需要创建时生成新的描述文件显示名称，保持应用标识、证书及设备关联不变。P00 增加固定的 Apple 错误代码和脱敏关键词，便于区分其他创建拒绝；不会自动删除 profile。用户在 0.3.1 仍遇到 P00 / HTTP 409，实际原因尚未取得，用户于 2026-11-10 确认安装完成，本轮未单独确认启动。调查和验证见[描述文件名称与 P00 证据](docs/spike/2026-11-10-profile-names.md)。

0.3.2 的 289 项 XCTest、4 项打包测试、模拟器/设备构建与 IPA 打包已通过[CI](https://github.com/kevin9525/locsign-public-build/actions/runs/42753288189)，最终 IPA 版本、应用标识、资源和 CRC 已核验。

保留 0.3.1 的一次明确重名重试、创建冲突后的严格验证复用及 P00–P07 分类。0.3.1 的 283 项 XCTest、4 项打包测试、模拟器/设备构建及 IPA 打包通过[CI](https://github.com/kevin9525/locsign-public-build/actions/runs/42742731948)，但用户后续真机仍失败，不能视为此次问题已解决。

继续提供 0.3.0 的一键安装：首次保存 Apple ID、团队、配对文件和设备地址，以后选择 IPA 并点“一键安装”，自动验证设备、复用有效材料（缺少或过期时申请）、签名及安装。签名标识按原应用与团队记住；本地 VPN 仍需自行开启。手动 P12 / PEM 和描述文件导入移到高级选项，连接页保留为排障工具。首次升级需重新导入一次配对文件，因为旧版只保存在内存；使用过个人签名标识的应用，第一次请在账号设置中选择与之前相同的标识。

一键流程的 268 项 XCTest、4 项打包测试、模拟器/设备构建及 IPA 打包已通过[CI](https://github.com/kevin9525/locsign-public-build/actions/runs/42590467632)。最终 IPA 已核验版本、应用标识、必需资源和 CRC。详细证据见[一键安装](docs/spike/2026-11-09-one-click-install.md)。新流程尚待真机复测；下文的真机通过记录属于 0.2.9。

0.2.9 / build 15 修复安装时的 `0xe8008017` 资源签名错误：描述文件在生成资源清单前写入，签名后只检查、不再补写文件。手机上的失败 IPA 已确认仅 `embedded.mobileprovision` 未进入签名清单，其余 77 项资源哈希匹配。固定版本 Zsign 以本地源码纳入一处条件补丁，详细证据见[资源签名修复](docs/spike/2026-11-09-signing-resource-seal.md)。更新后必须重新签名；旧的签名产物不会自动修复。

继续保留 0.2.8 的网络安装心跳：文件操作前完成首次应答，安装期间持续保活，结束时关闭连接；已知心跳失败阻止提交 Install。原 TLS 证书校验和服务顺序保持不变。0.2.8 真机重现已走通上传和提交安装，随后遇到上述资源校验错误；0.2.9 交付后，用户于 2026-11-09 确认 Feather 安装成功且能正常打开。对照证据见[安装心跳修复](docs/spike/2026-11-09-install-heartbeat.md)。

继续保留 0.2.6 的 C03 证书内容恢复、PEM/DER/Base64 支持、C01–C09 诊断、可选个人签名标识、Apple ID 登录、材料复用、手动导入和签名导出。申请结果不确定时保存私钥，重试只查询匹配证书，不重复提交 CSR；只有明确的申请拒绝才允许再次申请。查询不到匹配证书时会停止，不保证恢复成功。个人标识在同一团队与原 App 下固定，新标识作为独立应用安装。证书撤销必须确认精确列表；不会自动删除 profile 或修改 capability。详见[缺失证书内容恢复](docs/spike/2026-11-07-missing-certificate-content.md)。

自动申请当前接受无扩展/嵌套 App、未加密的单一 arm64 IPA；FAT 主程序、DER entitlement 与额外 capability 暂不支持。0.2.9 的 250 项 XCTest、4 项打包测试、模拟器/设备构建和 IPA 打包已通过[CI](https://github.com/kevin9525/locsign-public-build/actions/runs/42571719945)，最终 IPA 的版本、原应用标识、必需资源和 CRC 已核验。两条真实签名回归用例在修复前复现缺少描述文件资源项，修复后通过，包括主程序对资源清单的签名校验。用户于 2026-11-09 确认 Feather 安装成功且能正常打开，本次签名安装流程通过[真机验收](docs/apple-id-acceptance.md)；该结果不代表所有 IPA 均兼容。Apple ID 登录及配对已由用户确认成功；C03 恢复是否成功需按实际签名材料来源单独确认。0.2.9 尚未接入全局定位。

Anisette 默认地址为 `https://mac-ani.jkcoxson.com`。使用前需同意 UUID、ADI 握手消息/ADI blob 和来源 IP 披露；可换地址或关闭；已有材料可在重新校验后本机签名，无需访问提供方或 Apple。密码仅用于本次 Apple 登录，会话和私钥保存到本机专用 Keychain。覆盖更新保留资料；明确退出清除该账号资料和当前自动签名产物。

## 构建

需要 macOS、Xcode、XcodeGen。GitHub Actions 自动执行模拟器测试、设备构建并上传 `LocSign-ipa` 和 `LocSign-diagnostics`。

```sh
brew install xcodegen
python3 .ci/build-idevice.py
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

### 一键安装

1. 覆盖安装新版 LocSign，使用原 Apple ID 和 Bundle ID，保留已有账号材料。
2. 首次在“安装”页保存这台手机的配对 plist，设备地址默认 `10.7.0.1`。在“Apple ID 与签名设置”登录、确认提供方及选择团队；需要时输入验证码。
3. 开启 LocalDevVPN，保持手机解锁。选择 IPA，点“一键安装”；无需先测连接或加载描述文件。
4. 已使用个人签名标识的应用，首次升级请选择原团队和同一标识（原固定生成标识可重新生成），以后自动记住。新标识会作为独立应用安装。
5. 如需登录或确认撤销证书，会出现相应页面。只有明确确认列表后才撤销证书；拒绝则停止。
6. 安装失败时保留签名 IPA，可以导出或点“安装此签名文件”重试；不会自动重放安装请求。取消提交后的安装可能仍由设备完成。
7. “连接”页用于排障，与安装页共用保存的配对文件和地址。手动证书/描述文件签名在“高级选项”。

配对记录保存在应用私有 Application Support 中，使用完整文件保护且排除备份；密码不保存，会话及签名私钥仍在专用 Keychain。退出账号清除账号资料，设备配对可单独清除。签名标识属于应用/团队的更新设置，保留以避免后续更新换成另一个 App。

自动申请当前只接受无扩展、未加密的单一 arm64 App。缓存只复用匹配应用、团队和设备且重新校验有效的材料；切换应用时会申请相应描述文件，开发证书仍由已有流程复用。免费描述文件通常约 7 天，以实际验证结果为准。全局定位仍未接入。

详细接手记录：[docs/spike/2026-11-05-takeover-status.md](docs/spike/2026-11-05-takeover-status.md)。

本轮安装实现、CI 证据及真机步骤：[docs/spike/2026-11-05-install-validation.md](docs/spike/2026-11-05-install-validation.md)。

0.1.3 配对证书兼容修复与失败/成功测试证据：[docs/spike/2026-11-05-pairing-tls-subject-fix.md](docs/spike/2026-11-05-pairing-tls-subject-fix.md)。

0.1.4 真实证书对照、无 AKI 链构建修复和回归证据：[docs/spike/2026-11-06-pairing-chain-fix.md](docs/spike/2026-11-06-pairing-chain-fix.md)。

0.2.1 Feather 签名填充兼容修复和回归证据：[docs/spike/2026-11-07-feather-preflight-fix.md](docs/spike/2026-11-07-feather-preflight-fix.md)。

0.2.2 开发者服务错误诊断修复和复测步骤：[docs/spike/2026-11-07-developer-services-errors.md](docs/spike/2026-11-07-developer-services-errors.md)。

0.2.3 可选个人签名标识、注册错误分类和复测步骤：[docs/spike/2026-11-07-personal-signing-identifier.md](docs/spike/2026-11-07-personal-signing-identifier.md)。
