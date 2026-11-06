# LocSign M1 签名链 App 化 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 SwiftUI App（LocSign）内实现完整签名链：Apple ID 登录→证书/描述文件获取→IPA 重签→设备安装，真机完成一次「导入→签名→安装→启动」第三方 IPA。

**Architecture:** XcodeGen 文本化工程 + GitHub Actions macos-15 云构建出未签名 IPA（LocSign 本体先用 Sideloadly 装上真机）。签名引擎 = Swift 编排（ZIPFoundation 解包/重打包 + 从描述文件生成 entitlements）+ 嵌入式 ldid 二进制（posix_spawn 执行）；ProvisioningEngine = SideStore/apple-private-apis（登录+anisette）+ 自研 developerservices2 客户端；InstallEngine = 设备自连本机 lockdownd（TCP+配对文件+installation_proxy），OTA 路线仅作后备设计不实现。

**Tech Stack:** Swift 5 / SwiftUI（iOS 17.0+）、XcodeGen、ZIPFoundation、SideStore/apple-private-apis、ProcursusTeam/ldid、GitHub Actions（macos-15）、Git Bash（Windows 开发机）。

**Spec:** `docs/superpowers/specs/2026-11-04-locsign-ios18-design.md`（§6.2/6.3/6.4 模块设计、§11 里程碑 M1）；过程输入：`docs/spike/2026-11-M0-spike-report.md`（直连约束、解锁前置、会话语义）。

## Global Constraints

- 部署目标 **iOS 17.0**；Swift 语言模式 **5.0**（避开 Swift 6 严格并发与 C 互操作的摩擦）；仅 iPhone 竖屏。
- 账号：**免费 Apple ID**；证书 7 天有效、AppID 注册限频——所有 developerservices 调用必须 **fetch-first（先查后建，命中即复用）**。
- M0 铁律：**对 Apple 的全部 HTTPS 请求必须直连**（URLSessionConfiguration 的 connectionProxyDictionary 显式置空字典），禁止走系统代理。
- 本计划范围**不含**第三方 .p12 证书导入（spec 6.2 输入项之一，推迟到 M3——M1 的免费 Apple ID 全流程使用 App 内自生成的 key/cert，不需要 P12 解析）。记录为对 spec 的范围收窄。
- 私有协议实现一律以**本地参照源码**为准（pymobiledevice3 11.49.5 已在 `tools/spike/.venv` 可查源码；Feather/apple-private-apis 在 CI/本地 clone 后查），遇到与计划记忆不符的 API 以**实测源码为准并记 Ruling**——沿用 M0 的"先探明再实现"模式。
- UI 文案简体中文；包名 `com.locsign.app`；工程生成用 XcodeGen（仓库根 `project.yml`），**不提交 .xcodeproj**。
- CI 产物 = **未签名 IPA**（artifact 名 `LocSign-ipa`）；LocSign 本体上真机用 Sideloadly（M0 工具链，操作时关系统代理）。
- 每个任务结束：commit + 更新 `tools/devlog.md`（一行进度）。

## Review Focus

1. **系统 HTTP 代理污染 Apple 请求**（M0 实测 400 -80046）——期望所有 developerservices/auth 请求绕过系统代理。测试：Task 2 `DirectURLSessionTests`。
2. **ldid 二进制未嵌入或架构错误**（CI 构建产物缺 arm64 / 资源丢失 exec 位）——期望运行时从 bundle 拷出、chmod 755 后可执行并完成签名。测试：Task 3 CI 内 fixture 签名测试 + `nm` 无外部 SSL 符号检查。
3. **entitlements 与描述文件不一致**导致安装报 profile 不匹配——期望 entitlements 从 mobileprovision 的 Entitlements 字段生成而非手写。测试：Task 2 `ProfileParserTests`（断言 entitlementsXML 内容）。
4. **设备自连 lockdownd 被拒**（WiFi 隔离/配对记录失效/端口变更）——期望 probe 步骤给出明确诊断输出。测试：Task 5 probe 门禁（真机，GO/NO-GO）。
5. **免费账号限流**（连续 addAppId/addDevice 触发风控）——期望 coordinator 先 list 再 create。测试：Task 4 单测断言 fetch-first 顺序 + M1 报告记录实测结果。

---

### Task 1: 工程骨架 + CI 首绿

**Files:**
- Create: `project.yml`
- Create: `App/Sources/LocSignApp.swift`
- Create: `App/Sources/Info.plist`（由 XcodeGen 生成属性，此文件手写占位）
- Create: `.ci/build-ldid.sh`、`.ci/make-ipa.sh`（本任务先建空壳占位脚本，内容在 Task 3/1 补齐）
- Create: `.github/workflows/build.yml`
- Create: `tools/devlog.md`

**Interfaces:**
- Consumes: 无
- Produces: CI 绿色构建 + artifact `LocSign-ipa`（未签名 IPA）；后续所有任务的代码都放进 `App/Sources/` 树

- [ ] **Step 1: 写 `project.yml`**

```yaml
name: LocSign
options:
  bundleIdPrefix: com.locsign
  deploymentTarget:
    iOS: "17.0"
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "5.0"
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
    GENERATE_INFOPLIST_FILE: NO
packages:
  ZIPFoundation:
    url: https://github.com/weichsel/ZIPFoundation
    from: 0.9.19
  AppleAuthentication:
    url: https://github.com/SideStore/apple-private-apis
    branch: main
targets:
  LocSign:
    type: application
    platform: iOS
    sources:
      - path: App/Sources
    dependencies:
      - package: ZIPFoundation
      - package: AppleAuthentication
    info:
      path: App/Sources/Info.plist
      properties:
        CFBundleDisplayName: LocSign
        CFBundleShortVersionString: "0.1.0"
        CFBundleVersion: "1"
        UILaunchScreen: {}
        UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]
  LocSignTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: Tests/LocSignTests
    dependencies:
      - target: LocSign
```

注：`AppleAuthentication` 是 SideStore/apple-private-apis 的产品模块名——若 `xcodegen generate` 后 CI 在 SPM 解析阶段报模块名不存在，读该包 `Package.swift` 的 `products:` 段取真实名并修正（记 Ruling）。

- [ ] **Step 2: 写最小 App 源码与 Info.plist**

`App/Sources/Info.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>LocSign</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>UILaunchScreen</key><dict/>
  <key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array>
</dict>
</plist>
```

`App/Sources/LocSignApp.swift`：

```swift
import SwiftUI

@main
struct LocSignApp: App {
    var body: some Scene {
        WindowGroup {
            Text("LocSign 0.1 骨架")
                .font(.title)
        }
    }
}
```

- [ ] **Step 3: 写 CI workflow**

`.github/workflows/build.yml`：

```yaml
name: build
on:
  push:
    branches: [main]
  workflow_dispatch: {}
jobs:
  build:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Install XcodeGen
        run: brew install xcodegen
      - name: Build ldid for iOS
        run: ./.ci/build-ldid.sh
      - name: Generate Xcode project
        run: xcodegen generate
      - name: Unit tests (simulator)
        run: |
          xcodebuild test -project LocSign.xcodeproj -scheme LocSign \
            -destination 'platform=iOS Simulator,name=iPhone 16' \
            -derivedDataPath build 2>&1 | xcbeautify || true
      - name: Build device (unsigned)
        run: |
          xcodebuild build -project LocSign.xcodeproj -scheme LocSign \
            -sdk iphoneos -configuration Release \
            CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
            -derivedDataPath build 2>&1 | xcbeautify
      - name: Assemble unsigned IPA
        run: ./.ci/make-ipa.sh
      - uses: actions/upload-artifact@v4
        with:
          name: LocSign-ipa
          path: build/LocSign.ipa
```

注意：`xcodebuild test` 行首跑时 Tests 目录还不存在（Task 2 才建），本任务先写成 `|| true` 容忍；Task 2 建立测试后**必须去掉 `|| true`** 让测试失败阻塞 CI（在 Task 2 的步骤里做）。若 runner 默认模拟器名不是 `iPhone 16`，用 `xcrun simctl list devices available` 的输出改名（记 Ruling）。

`.ci/build-ldid.sh`（Task 1 空壳，Task 3 补齐）：

```bash
#!/bin/bash
set -euo pipefail
echo "Task 3 实现"
```

`.ci/make-ipa.sh`：

```bash
#!/bin/bash
set -euo pipefail
APP=$(find build/Build/Products/Release-iphoneos -maxdepth 1 -name "*.app" | head -n 1)
test -n "$APP" || { echo "找不到 .app"; exit 1; }
mkdir -p build/Payload
cp -R "$APP" build/Payload/
cd build && zip -qry LocSign.ipa Payload && cd ..
echo "IPA: build/LocSign.ipa ($(du -h build/LocSign.ipa | cut -f1))"
```

- [ ] **Step 4: 用户手动——建 GitHub 私有仓库并首次推送**

1. 浏览器打开 https://github.com/new ，Repository name 填 `locsign`，选 **Private**，**不要**勾任何初始化文件，点 Create repository。
2. 在仓库根（Git Bash）执行（把 `<你的用户名>` 换掉）：

```bash
git remote add origin https://github.com/<你的用户名>/locsign.git
git push -u origin main
```

首次推送 Windows 凭据管理器会弹浏览器授权——按提示登录即可。

- [ ] **Step 5: 验证 CI 首绿**

浏览器打开仓库 Actions 页，等 `build` workflow 跑完。**验收：绿灯 + Artifact 区出现 `LocSign-ipa` 可下载**。红灯时把失败 step 的最后 30 行原文贴回会话排查（首跑常见问题：SPM 模块名、模拟器名、brew 装不上 xcodegen——逐个按 Ruling 修）。

- [ ] **Step 6: 提交与 devlog**

```bash
git add -A
git commit -m "build: XcodeGen 工程骨架 + CI 首绿"
echo "- $(date +%F) Task1 工程骨架+CI 首绿" >> tools/devlog.md
git add tools/devlog.md && git commit --amend --no-edit
```

---

### Task 2: Infra 层（直连网络、日志、错误、plist 编解码、描述文件解析）

**Files:**
- Create: `App/Sources/Infra/DirectURLSession.swift`
- Create: `App/Sources/Infra/AppLogger.swift`
- Create: `App/Sources/Infra/LocSignError.swift`
- Create: `App/Sources/Infra/PlistCodec.swift`
- Create: `App/Sources/Infra/ProfileParser.swift`
- Create: `Tests/LocSignTests/DirectURLSessionTests.swift`
- Create: `Tests/LocSignTests/PlistCodecTests.swift`
- Create: `Tests/LocSignTests/ProfileParserTests.swift`
- Modify: `.github/workflows/build.yml`（去掉 test 步的 `|| true`）

**Interfaces:**
- Consumes: Task 1 工程骨架
- Produces:
  - `DirectURLSession.make() -> URLSession`（空代理字典=绕过系统代理）
  - `enum LocSignError: Error { case signing(String), provisioning(String), install(String), infra(String) }`（LocalizedError，中文描述）
  - `AppLogger.log(_ level: Level, _ tag: String, _ message: String)`（内存环形缓冲 + 落盘 Documents/logs/app.log）
  - `enum PlistCodec { static func decode(_ data: Data) throws -> Any; static func encodeXML(_ object: Any) throws -> Data }`
  - `struct ProvisioningProfileData { let raw: Data; let payload: [String: Any]; var bundleID: String { get }; var teamID: String { get }; var expiry: Date { get }; var entitlementsXML: String { get } }`
  - `enum ProfileParser { static func parse(_ mobileprovision: Data) throws -> ProvisioningProfileData }`

- [ ] **Step 1: 写失败测试 `Tests/LocSignTests/DirectURLSessionTests.swift`**

```swift
import XCTest
@testable import LocSign

final class DirectURLSessionTests: XCTestCase {
    func testProxyDictionaryIsEmpty() throws {
        let config = DirectURLSession.configuration()
        XCTAssertEqual(config.connectionProxyDictionary?["HTTPProxyHost"], nil)
        XCTAssertEqual(config.connectionProxyDictionary?["HTTPSPort"], nil)
        // 空字典（非 nil）是关键：显式声明"无代理"覆盖系统配置
        XCTAssertNotNil(config.connectionProxyDictionary)
        XCTAssertTrue(config.connectionProxyDictionary!.isEmpty)
    }
    func testSessionCreated() {
        let session = DirectURLSession.make()
        XCTAssertEqual(session.configuration.connectionProxyDictionary?.isEmpty, true)
    }
}
```

- [ ] **Step 2: 写失败测试 `Tests/LocSignTests/PlistCodecTests.swift`**

```swift
import XCTest
@testable import LocSign

final class PlistCodecTests: XCTestCase {
    func testXMLRoundtrip() throws {
        let dict: [String: Any] = ["Name": "LocSign", "Count": 3, "Flag": true]
        let xml = try PlistCodec.encodeXML(dict)
        let back = try PlistCodec.decode(xml) as! [String: Any]
        XCTAssertEqual(back["Name"] as? String, "LocSign")
        XCTAssertEqual(back["Count"] as? Int, 3)
    }
    func testBPlistDecode() throws {
        var data = Data("bplist00".utf8)
        data.append(Data(repeating: 0, count: 16))  // 最小假体，decode 应尝试 PropertyListSerialization
        XCTAssertThrowsError(try PlistCodec.decode(data)) // 损坏 bplist 应抛错而非崩溃
    }
}
```

- [ ] **Step 3: 写失败测试 `Tests/LocSignTests/ProfileParserTests.swift`**

```swift
import XCTest
@testable import LocSign

final class ProfileParserTests: XCTestCase {
    // 合成 mobileprovision：前缀垃圾字节(模拟 CMS DER) + XML plist payload
    func testParseSyntheticProfile() throws {
        let payload = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Name</key><string>LocSign Dev</string>
        <key>TeamIdentifier</key><array><string>TEAM12345</string></array>
        <key>application-identifier</key><string>TEAM12345.com.test.app</string>
        <key>ExpirationDate</key><date>2026-11-11T00:00:00Z</date>
        <key>Entitlements</key><dict>
          <key>application-identifier</key><string>TEAM12345.com.test.app</string>
          <key>get-task-allow</key><true/>
        </dict>
        <key>ProvisionedDevices</key><array><string>REDACTED-DEVICE-UDID</string></array>
        </dict></plist>
        """
        let raw = Data(repeating: 0xAB, count: 1024) + Data(payload.utf8)
        let profile = try ProfileParser.parse(raw)
        XCTAssertEqual(profile.bundleID, "com.test.app")
        XCTAssertEqual(profile.teamID, "TEAM12345")
        XCTAssertEqual(profile.entitlementsXML.contains("get-task-allow"), true)
        XCTAssertEqual(profile.deviceUDIDs, ["REDACTED-DEVICE-UDID"])
    }
}
```

- [ ] **Step 4: 跑测试确认 RED**

推送到 GitHub 触发 CI（test 步当前 `|| true` 不阻塞，看日志确认 3 个测试类**编译失败或断言失败**即可，本地无 Xcode，CI 是唯一验证场）：
`git push` → Actions 日志出现 `DirectURLSessionTests`/`PlistCodecTests`/`ProfileParserTests` 的 FAIL/编译错误。
预期：FAIL（类型不存在）。

- [ ] **Step 5: 实现 Infra 四件套**

`App/Sources/Infra/DirectURLSession.swift`：

```swift
import Foundation

enum DirectURLSession {
    /// 空 connectionProxyDictionary 覆盖系统代理配置——M0 实测机房代理 IP 会触发 Apple 风控
    static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.default
        c.connectionProxyDictionary = [:]
        c.httpAdditionalHeaders = [:]
        c.timeoutIntervalForRequest = 30
        return c
    }
    static func make() -> URLSession { URLSession(configuration: configuration()) }
}
```

`App/Sources/Infra/LocSignError.swift`：

```swift
import Foundation

enum LocSignError: LocalizedError {
    case signing(String), provisioning(String), install(String), infra(String)
    var errorDescription: String? {
        switch self {
        case .signing(let r): return "签名失败：\(r)"
        case .provisioning(let r): return "证书服务失败：\(r)"
        case .install(let r): return "安装失败：\(r)"
        case .infra(let r): return "内部错误：\(r)"
        }
    }
}
```

`App/Sources/Infra/AppLogger.swift`：

```swift
import Foundation

enum AppLogger {
    enum Level: String { case debug, info, warn, error }
    private static let queue = DispatchQueue(label: "applog")
    private static var buffer: [String] = []
    private static var logURL: URL? {
        guard let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return doc.appendingPathComponent("logs/app.log")
    }
    static func log(_ level: Level, _ tag: String, _ message: String) {
        let line = "\(Date()) [\(level.rawValue.uppercased())] \(tag): \(message)"
        queue.async {
            buffer.append(line)
            if buffer.count > 2000 { buffer.removeFirst(buffer.count - 2000) }
            if let url = logURL {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? line.appendLineTo(file: url)
            }
        }
    }
}
extension String {
    func appendLineTo(file: URL) throws {
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile(); handle.write(Data((self + "\n").utf8)); try? handle.close()
        } else {
            try (self + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
```

`App/Sources/Infra/PlistCodec.swift`：

```swift
import Foundation

enum PlistCodec {
    static func decode(_ data: Data) throws -> Any {
        try PropertyListSerialization.propertyList(from: data, format: nil)
    }
    static func encodeXML(_ object: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }
    static func encodeBinary(_ object: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
    }
}
```

`App/Sources/Infra/ProfileParser.swift`：

```swift
import Foundation

struct ProvisioningProfileData {
    let raw: Data
    let payload: [String: Any]
    var bundleID: String {
        let appID = payload["application-identifier"] as? String ?? ""
        let team = teamID
        return String(appID.dropFirst(team.count + 1))
    }
    var teamID: String { (payload["TeamIdentifier"] as? [String])?.first ?? "" }
    var expiry: Date { payload["ExpirationDate"] as? Date ?? .distantPast }
    var deviceUDIDs: [String] { payload["ProvisionedDevices"] as? [String] ?? [] }
    var name: String { payload["Name"] as? String ?? "" }
    /// 从 Entitlements 字段生成签名用 entitlements XML——保证与描述文件一致（Review Focus 3）
    var entitlementsXML: String {
        let ents = payload["Entitlements"] as? [String: Any] ?? [:]
        return (try? PlistCodec.encodeXML(ents)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

enum ProfileParser {
    static func parse(_ mobileprovision: Data) throws -> ProvisioningProfileData {
        // mobileprovision = CMS(DER) 包着的 plist payload；定位 plist 边界提取
        guard let range = mobileprovision.range(of: Data("<?xml".utf8)),
              let end = mobileprovision.range(of: Data("</plist>".utf8))
        else { throw LocSignError.infra("描述文件中未找到 plist payload") }
        let slice = mobileprovision.subdata(in: range.lowerBound..<end.upperBound)
        let payload = try PlistCodec.decode(slice) as? [String: Any]
        guard let payload else { throw LocSignError.infra("描述文件 payload 非 dict") }
        return ProvisioningProfileData(raw: mobileprovision, payload: payload)
    }
}
```

- [ ] **Step 6: CI 测试转阻塞 + 跑绿**

修改 `.github/workflows/build.yml` 的 test 步：删掉行尾 `|| true`（原 4 行变 3 行）。推送后确认 Actions 全绿（3 个测试 PASS + IPA artifact 生成）。
预期：PASS。

- [ ] **Step 7: 提交 + devlog**

```bash
git add -A && git commit -m "feat(infra): 直连网络/日志/错误/plist/描述文件解析 + CI 测试阻塞化"
echo "- $(date +%F) Task2 Infra 层 + 测试转阻塞" >> tools/devlog.md && git add -A && git commit --amend --no-edit
```

---

### Task 3: SigningEngine（嵌入式 ldid + IPA 解包重签重打包）

**Files:**
- Create: `.ci/build-ldid.sh`（补齐实现）
- Create: `App/Sources/Engines/Signing/LdidRunner.swift`
- Create: `App/Sources/Engines/Signing/IPAPacker.swift`
- Create: `App/Sources/Engines/Signing/SigningEngine.swift`
- Create: `Tests/LocSignTests/IPAPackerTests.swift`

**Interfaces:**
- Consumes: Task 2 的 `ProfileParser`/`ProvisioningProfileData.entitlementsXML`、`LocSignError.signing`、`AppLogger`
- Produces:
  - `final class LdidRunner { static let shared: LdidRunner; func run(_ args: [String]) throws -> String }`
  - `enum IPAPacker { static func unpack(_ ipaURL: URL, into dir: URL) throws -> URL /* 返回 .app URL */; static func repack(appURL: URL, outputURL: URL) throws }`
  - `func isMachO(_ url: URL) -> Bool`
  - `final class SigningEngine { static let shared: SigningEngine; func sign(ipaURL: URL, certPEM: String, keyPEM: String, profile: ProvisioningProfileData) async throws -> URL /* 签名后 IPA */ }`

- [ ] **Step 1: 补齐 `.ci/build-ldid.sh`**

```bash
#!/bin/bash
set -euo pipefail
RES_DIR="$GITHUB_WORKSPACE/App/Sources/Engines/Signing/Resources"
mkdir -p "$RES_DIR"
rm -rf /tmp/ldid-src
git clone --depth 1 https://github.com/ProcursusTeam/ldid /tmp/ldid-src
cd /tmp/ldid-src
SDK=$(xcrun -sdk iphoneos --show-sdk-path)
# ProcursusTeam/ldid 的实际构建方式以其 Makefile 为准；主路径=手工 clang++ 编单文件。
# 若因缺 OpenSSL 失败（nm 能看到 SSL_*），改为 make 的 ios 目标或退回 saurik 源（计划附录 A）。
xcrun -sdk iphoneos clang++ -arch arm64 -std=c++17 -O2 -o "$RES_DIR/ldid" ldid.cpp 2>/tmp/ldid-cc.log \
  || { echo "主路径失败，Makefile 构建回退："; cat /tmp/ldid-cc.log; make -j4 CC="xcrun -sdk iphoneos clang" CXX="xcrun -sdk iphoneos clang++" ARCHFLAGS="-arch arm64 -isysroot $SDK" ldid && cp ldid "$RES_DIR/ldid"; }
# 审查：不得依赖外部 OpenSSL（Review Focus 2）
if nm "$RES_DIR/ldid" | grep -q " _SSL_"; then echo "ldid 依赖 OpenSSL——按附录 A 处理"; exit 1; fi
codesign -f -s - "$RES_DIR/ldid"   # 嵌入二进制需自带 ad-hoc 签名
chmod 755 "$RES_DIR/ldid"
file "$RES_DIR/ldid"
```

附录 A（写进计划供执行者查）：saurik 原版 ldid（自带 crypto、无 OpenSSL）：`git clone https://github.com/nicklockwood/ldid` 无效时用 `git clone https://git.saurik.com/ldid.git`；若都不可达，改用 **zsign 方案**（依赖 iOS OpenSSL 构建，脚本见 zsign 仓库 README 的 iOS 段）——发生该切换记 Ruling 并同步改 LdidRunner。

- [ ] **Step 2: 写失败测试 `Tests/LocSignTests/IPAPackerTests.swift`（CI 上跑，含真实签名）**

```swift
import XCTest
@testable import LocSign

final class IPAPackerTests: XCTestCase {
    /// 在 runner 上现编一个最小 MachO 作 fixture（macOS 片段即可被 ldid 签名）
    func testUnpackSignRepackRoundtrip() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let src = tmp.appendingPathComponent("hello.c")
        try "#include <stdio.h>\nint main(){return 0;}\n".write(to: src, atomically: true, encoding: .utf8)
        let bin = tmp.appendingPathComponent("hello")
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        cc.arguments = ["clang", src.path, "-o", bin.path]
        try cc.run(); cc.waitUntilExit()
        XCTAssertEqual(cc.terminationStatus, 0)

        // 组装假 IPA：Payload/Demo.app/{Demo(hello 改名), Info.plist, embedded.mobileprovision}
        let appDir = tmp.appendingPathComponent("Payload/Demo.app")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bin, to: appDir.appendingPathComponent("Demo"))
        let infoPlist = try PlistCodec.encodeXML(["CFBundleIdentifier": "com.test.app", "CFBundleExecutable": "Demo"])
        try infoPlist.write(to: appDir.appendingPathComponent("Info.plist"))
        let profileRaw = try syntheticProfileData(bundleID: "com.test.app")
        try profileRaw.write(to: appDir.appendingPathComponent("embedded.mobileprovision"))
        let zip = tmp.appendingPathComponent("demo.ipa")
        try IPAPacker.makeZip(fromDirectory: tmp.appendingPathComponent("Payload"), to: zip)

        // unpack → 校验结构
        let unpacked = try IPAPacker.unpack(zip, into: tmp.appendingPathComponent("work"))
        XCTAssertEqual(unpacked.lastPathComponent, "Demo.app")

        // sign（ldid 真实执行）
        let profile = try ProfileParser.parse(profileRaw)
        _ = try SigningEngine.shared.signSyncForTesting(
            unpackedApp: unpacked,
            certPEM: Self.selfSignedCertPEM, keyPEM: Self.selfSignedKeyPEM,
            profile: profile, outputURL: tmp.appendingPathComponent("signed.ipa"))

        // 验证：输出 IPA 内 Demo 二进制含 CMS 签名（codesign 校验）
        let signedApp = tmp.appendingPathComponent("signed-check/Demo.app")
        try FileManager.default.createDirectory(at: signedApp.deletingLastPathComponent(), withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", tmp.appendingPathComponent("signed.ipa").path, "-d", signedApp.deletingLastPathComponent().path]
        try unzip.run(); unzip.waitUntilExit()
        let cs = Process()
        let pipe = Pipe()
        cs.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        cs.arguments = ["-dv", signedApp.appendingPathComponent("Demo").path]
        cs.standardError = pipe
        try cs.run(); cs.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("Signature") || out.contains("signed"), "codesign 未识别签名: \(out)")
    }
}
```

注：`Self.selfSignedCertPEM/selfSignedKeyPEM` 在测试内用 `openssl req -x509 -newkey rsa:2048` 现生成（测试 setUp 里 Process 调 openssl，runner 自带 openssl）；`SigningEngine.signSyncForTesting` 是 Task 3 实现里的**同步测试入口**（内部同 async 路径）；`ZIPArchive.make` 是 IPAPacker 内对 ZIPFoundation 的薄包装。这两处都是接口定义的一部分，实现时必须暴露。

- [ ] **Step 3: 实现 LdidRunner.swift**

```swift
import Foundation

final class LdidRunner {
    static let shared = LdidRunner()
    private let workBinary: URL

    private init() throws {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let dst = support.appendingPathComponent("ldid")
        // 资源里的 ldid 无执行位——拷到容器再 chmod（Feather 同款做法）
        if let bundled = Bundle.main.url(forResource: "ldid", withExtension: nil) {
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: bundled, to: dst)
        }
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
        try? fm.setAttributes(attrs, ofItemAtPath: dst.path)
        workBinary = dst
    }

    func run(_ args: [String]) throws -> String {
        let outPipe = Pipe(), errPipe = Pipe()
        var attr = posix_spawnattr_t()
        posix_spawnattr_init(&attr)
        var fileActions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, outPipe.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe.fileHandleForWriting.fileDescriptor, 2)
        let argvC = ([workBinary.path] + args).withCStringArray { $0 }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, workBinary.path, &fileActions, &attr, argvC, environ)
        guard rc == 0 else { throw LocSignError.signing("ldid 启动失败 rc=\(rc)") }
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        guard status == 0 else {
            throw LocSignError.signing("ldid 退出码 \(status)：\(String(data: errData, encoding: .utf8) ?? "")")
        }
        return String(data: errData, encoding: .utf8) ?? ""
    }
}
extension Array where Element == String {
    func withCStringArray<R>(_ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
        let cStrings = self.map { strdup($0) } + [nil]
        defer { cStrings.compactMap { $0 }.forEach { free($0) } }
        return body(cStrings.map { UnsafeMutablePointer<CChar>?($0) } as [UnsafeMutablePointer<CChar>?])
    }
}
```

- [ ] **Step 4: 实现 IPAPacker.swift 与 SigningEngine.swift（核心编排）**

`IPAPacker` 要点（完整实现照此写）：

```swift
import Foundation
import ZIPFoundation

func isMachO(_ url: URL) -> Bool {
    guard let fh = FileHandle(forReadingAtPath: url.path), let magic = try? fh.read(upToCount: 4) else { return false }
    let m = [UInt8](magic)
    // MH_MAGIC_64 / MH_CIGAM_64 / FAT_MAGIC（瘦/胖包都算）
    return m.count == 4 && ((m[0],m[1],m[2],m[3]) == (0xcf,0xfa,0xed,0xce)
        || (m[0],m[1],m[2],m[3]) == (0xce,0xfa,0xed,0xcf)
        || (m[0],m[1],m[2],m[3]) == (0xca,0xfe,0xba,0xbe)
        || (m[0],m[1],m[2],m[3]) == (0xbe,0xba,0xfe,0xca))
}

enum IPAPacker {
    static func unpack(_ ipaURL: URL, into dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: ipaURL, to: dir)
        let payload = dir.appendingPathComponent("Payload")
        guard let app = try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" })
        else { throw LocSignError.signing("IPA 内找不到 .app") }
        return app
    }
    static func repack(appURL: URL, outputURL: URL) throws { /* 删旧 zip；从 appURL.parent 以 ZIPFoundation zipItem 生成 */ }
    static func makeZip(fromDirectory: URL, to: URL) throws { /* 同上薄包装，供测试 */ }
    /// 收集需要重签的 MachO：①主二进制=Info.plist 的 CFBundleExecutable；
    /// ②Frameworks/ 下每个 *.framework 的主二进制；③PlugIns/ 下每个 *.appex 内主二进制（读各自 Info.plist）
    static func machOList(in appURL: URL) throws -> [URL]
}
```

`SigningEngine`：

```swift
import Foundation

final class SigningEngine {
    static let shared = SigningEngine()

    /// 权威入口。步骤：unpack → 写 embedded.mobileprovision → 对每个 MachO 调 ldid → repack
    func sign(ipaURL: URL, certPEM: String, keyPEM: String, profile: ProvisioningProfileData) async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let app = try IPAPacker.unpack(ipaURL, into: tmp.appendingPathComponent("work"))
        try profile.raw.write(to: app.appendingPathComponent("embedded.mobileprovision"))
        let entsFile = tmp.appendingPathComponent("entitlements.plist")
        try profile.entitlementsXML.data(using: .utf8)!.write(to: entsFile)
        let keyFile = tmp.appendingPathComponent("key.pem"), certFile = tmp.appendingPathComponent("cert.pem")
        try keyPEM.write(to: keyFile, atomically: true, encoding: .utf8)
        try certPEM.write(to: certFile, atomically: true, encoding: .utf8)
        for macho in try IPAPacker.machOList(in: app) {
            // ldid 真实证书签名形态——首跑前读 ProcursusTeam/ldid 的 usage()（ldid.cpp 主函数帮助文本）
            // 核对参数附着方式（-K<path> 还是 -K <path>），以源码为准，不符记 Ruling
            try LdidRunner.shared.run(["-K", keyFile.path, "-I", certFile.path, "-S" + entsFile.path, macho.path])
            AppLogger.log(.info, "sign", "已签 \(macho.lastPathComponent)")
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("signed-\(UUID().uuidString).ipa")
        try IPAPacker.repack(appURL: app, outputURL: out)
        return out
    }
    /// 测试专用同步入口（CI 用）；生产路径走 sign()
    func signSyncForTesting(unpackedApp: URL, certPEM: String, keyPEM: String, profile: ProvisioningProfileData, outputURL: URL) throws { /* 同上逻辑的同步版本 */ }
}
```

- [ ] **Step 5: 推送 → 看 CI RED→GREEN**

先推送（测试存在而实现缺失 → CI 编译失败 = RED 证据记录到 devlog），随后补齐实现再推送。
预期：CI 全绿，`IPAPackerTests` PASS，日志含 `已签 Demo`。
预期：PASS。

- [ ] **Step 6: 提交 + devlog**

```bash
git add -A && git commit -m "feat(signing): ldid 嵌入 + IPA 解包重签重打包 + CI fixture 签名测试"
echo "- $(date +%F) Task3 SigningEngine 完成（ldid CI 构建 + fixture 签名测试）" >> tools/devlog.md && git add -A && git commit --amend --no-edit
```

---

### Task 4: ProvisioningEngine（Apple ID 登录 → 证书 → 描述文件）

**Files:**
- Create: `App/Sources/Engines/Provisioning/CSRGenerator.swift`
- Create: `App/Sources/Engines/Provisioning/DeveloperservicesClient.swift`
- Create: `App/Sources/Engines/Provisioning/ProvisioningCoordinator.swift`
- Create: `Tests/LocSignTests/CSRGeneratorTests.swift`
- Create: `Tests/LocSignTests/FetchFirstOrderTests.swift`

**Interfaces:**
- Consumes: Task 2 `DirectURLSession`/`LocSignError.provisioning`/`AppLogger`
- Produces:
  - `struct AnisetteHeaders { let values: [String: String] }`
  - `final class CSRGenerator { static func generate(commonName: String) throws -> (keyPEM: String, csrPEM: String) }`（RSA-2048，`SecKeyCreateRandomKey` + 手工 DER CSR）
  - `final class DeveloperservicesClient { init(anisette: @escaping () async throws -> AnisetteHeaders, sessionHeaders: @escaping () -> [String: String]); func action(_ action: String, form fields: [String: String]) async throws -> [String: Any] }`
  - `protocol DeveloperservicesClientProtocol { func action(_ action: String, form fields: [String: String]) async throws -> [String: Any] }`（DeveloperservicesClient 遵循；测试用内存 stub 遵循同一协议）
  - `ProvisioningCoordinator.makeForTesting(client: DeveloperservicesClientProtocol) -> ProvisioningCoordinator`
  - `final class ProvisioningCoordinator { func signIn(account: String, password: String, codeProvider: @escaping () async -> String) async throws; func fetchOrCreateCert(deviceUDID: String) async throws -> (certPEM: String, keyPEM: String, serial: String); func fetchOrCreateProfile(bundleID: String, deviceUDID: String) async throws -> ProvisioningProfileData; func registerAppIDIfMissing(bundleID: String) async throws }`

- [ ] **Step 1: 读依赖源码核对 API（探明步，产物=简记进 devlog）**

clone 并读两个参照（只读，不改）：
- `git clone --depth 1 https://github.com/SideStore/apple-private-apis /tmp/apa` → 读 `Sources/AppleAuthentication/` 的公开类型：确认登录入口类型名（搜 `public class`/`func login`）、2FA 回调形态、anisette 头获取函数名。
- `git clone --depth 1 https://github.com/khcrysalis/Feather /tmp/feather` → 读其 developerservices 调用（搜 `developerservices2`）与 CSR 生成文件：抄录**端点 action 名与表单字段名**（`listTeams`/`listAppIds`/`addAppId`/`listAllDeviceIds`/`submitDevelopmentCertificate`/`downloadTeamProvisioningProfile` 等的真实拼写与参数）到 devlog。

- [ ] **Step 2: 写失败测试 `CSRGeneratorTests.swift` 与 `FetchFirstOrderTests.swift`**

```swift
import XCTest
@testable import LocSign

final class CSRGeneratorTests: XCTestCase {
    func testGenerateProducesPEM() throws {
        let out = try CSRGenerator.generate(commonName: "LocSign Dev")
        XCTAssertTrue(out.keyPEM.contains("BEGIN"))
        XCTAssertTrue(out.csrPEM.contains("CERTIFICATE REQUEST"))
        // CSR 能被 openssl 解析（CI runner 自带 openssl）
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("csr.pem")
        try out.csrPEM.write(to: tmp, atomically: true, encoding: .utf8)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = ["req", "-in", tmp.path, "-noout", "-verify"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        XCTAssertTrue(p.terminationStatus == 0, "openssl 无法解析 CSR")
    }
}

final class FetchFirstOrderTests: XCTestCase {
    func testCoordinatorListsBeforeCreates() async throws {
        let recorder = ActionRecorder()   // 测试内定义：记录 action 调用顺序
        let coord = ProvisioningCoordinator.makeForTesting(client: recorder.stubClient)
        try await coord.registerAppIDIfMissing(bundleID: "com.test.app")
        // 断言顺序：先 listAppIds，命中后不得调用 addAppId
        XCTAssertEqual(recorder.actions.first, "listAppIds")
        XCTAssertFalse(recorder.actions.contains("addAppId"), "已存在时不得重复创建（Review Focus 5）")
    }
}
```

（`ActionRecorder`/`stubClient`：测试文件内实现一个内存 client，实现与 `DeveloperservicesClient` 相同的 `action(_:form:)` 签名返回固定 dict。）

- [ ] **Step 3: 实现 CSRGenerator（DER 手工构建）**

要点代码（DERBuilder + CSR，完整文件照此补全）：

```swift
import Foundation
import Security

enum DERBuilder {
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var len = content.count
        var lenBytes: [UInt8] = len < 0x80 ? [UInt8(len)] : []
        if len >= 0x80 { var b: [UInt8] = []; while len > 0 { b.insert(UInt8(len & 0xff), at: 0); len >>= 8 }
            lenBytes = [UInt8(0x80 | b.count)] + b }
        return [tag] + lenBytes + content
    }
    static func sequence(_ c: [UInt8]) -> [UInt8] { tlv(0x30, c) }
    static func set(_ c: [UInt8]) -> [UInt8] { tlv(0x31, c) }
    static func integer(_ v: Int) -> [UInt8] { tlv(0x02, [UInt8(v)]) }
    static func oid(_ bytes: [UInt8]) -> [UInt8] { tlv(0x06, bytes) }
    static func utf8String(_ s: String) -> [UInt8] { tlv(0x0c, Array(s.utf8)) }
    static func null() -> [UInt8] { tlv(0x05, []) }
    static func bitString(_ c: [UInt8]) -> [UInt8] { tlv(0x03, [0] + c) }
}
let oidCommonName: [UInt8] = [0x55, 0x04, 0x03]
let oidRSAEncryption: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]
let oidSHA256WithRSA: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b]

final class CSRGenerator {
    static func generate(commonName: String) throws -> (keyPEM: String, csrPEM: String) {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrIsPermanent as String: true,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true],
        ]
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &err) else {
            throw LocSignError.provisioning("密钥生成失败: \(String(describing: err?.takeRetainedValue()))")
        }
        // 1) 公钥 DER：SecKeyCopyExternalRepresentation = PKCS#1 → 包成 SubjectPublicKeyInfo
        var extErr: Unmanaged<CFError>?
        let pkcs1 = SecKeyCopyExternalRepresentation(key, &extErr) as Data
        let spki = DERBuilder.sequence(DERBuilder.sequence(DERBuilder.oid(oidRSAEncryption) + DERBuilder.null())
            + DERBuilder.bitString(Array(pkcs1)))
        // 2) CSR 结构：SEQUENCE{ version, subject(CN), spki, [attributes 空], algId, sigBitString }
        let name = DERBuilder.set(DERBuilder.sequence(DERBuilder.sequence(DERBuilder.oid(oidCommonName) + DERBuilder.utf8String(commonName))))
        let tbs = DERBuilder.sequence(DERBuilder.integer(0) + name + spki
            + DERBuilder.sequence([]))  // attributes 上下文标记略——以 openssl 校验通过为准，失败时按 DER 规范补 [0] 标记
        // 3) 用密钥对 tbs 签名（SecKeyCreateSignature，sha256WithRSA）
        var sigErr: Unmanaged<CFError>?
        let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(tbs) as CFData, &sigErr)
        guard let sig else { throw LocSignError.provisioning("CSR 签名失败") }
        let alg = DERBuilder.sequence(DERBuilder.oid(oidSHA256WithRSA) + DERBuilder.null())
        let csr = DERBuilder.sequence(tbs + alg + DERBuilder.bitString(Array(sig)))
        return (keyPEM: Self.pem(type: "PRIVATE KEY", der: []) /* 私钥 PEM 由 Task 4 实现：SecKey→PKCS#1→PKCS#8 包装 */,
                csrPEM: Self.pem(type: "CERTIFICATE REQUEST", der: csr))
    }
    static func pem(type: String, der: [UInt8]) -> String { /* base64 每 64 字符换行 + BEGIN/END 包裹 */ }
}
```

注：tbs 的 attributes 段与 PKCS#8 包装是本文件两个**必须用 openssl 验证通过才收工**的点（测试已卡）；细节如不对，对照 Feather 的 CSR 生成实现修正（Task 4 Step 1 已 clone 到 /tmp/feather）。私钥 PEM：SecKeyCopyExternalRepresentation 得 PKCS#1，外包一层 PKCS#8 头（`30 82 … 02 01 00 30 0d 06 09 2a864886f70d010101 05 00 04 82 …` + PKCS#1 内容），RSA-2048 固定模板，Feather 同款。

- [ ] **Step 4: 实现 DeveloperservicesClient 与 ProvisioningCoordinator**

```swift
import Foundation

final class DeveloperservicesClient {
    private let base = URL(string: "https://developerservices2.apple.com/services/QH65B2/ios/")!
    private let session = DirectURLSession.make()   // 直连铁律
    let anisette: () async throws -> AnisetteHeaders
    let sessionHeaders: () -> [String: String]      // 登录态 cookie（PET 等）

    init(anisette: @escaping () async throws -> AnisetteHeaders, sessionHeaders: @escaping () -> [String: String]) { ... }

    /// developerservices2 = 表单 POST + XML plist 应答 {result, ...}
    func action(_ action: String, form fields: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: base.appendingPathComponent(action))
        req.httpMethod = "POST"
        let ani = try await anisette().values
        for (k, v) in ani { req.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in sessionHeaders() { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = fields.map { "\($0)=\($1.urlEncoded)" }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        guard (resp as! HTTPURLResponse).statusCode == 200 else { throw LocSignError.provisioning("HTTP \(...)") }
        guard let dict = try? PlistCodec.decode(data) as? [String: Any] else { throw LocSignError.provisioning("应答非 plist") }
        guard (dict["result"] as? Int) == 1 else { throw LocSignError.provisioning("Apple 拒绝: \(dict)") }
        return dict
    }
    // 便捷方法（字段名以 Step 1 抄录为准）：listTeams / listAppIds / addAppId / listAllDeviceIds / submitDevelopmentCertificate / downloadTeamProvisioningProfile
}

final class ProvisioningCoordinator {
    // 状态：teamId、appIdId、cert、profile
    func signIn(account: String, password: String, codeProvider: @escaping () async -> String) async throws {
        // apple-private-apis 登录（API 名以 Step 1 实测为准）；2FA 时调 codeProvider 取验证码（M0 待验证项落点）
    }
    func registerAppIDIfMissing(bundleID: String) async throws { /* listAppIds → 命中即复用（Review Focus 5）→ 未命中 addAppId(enabledFeatures=空) */ }
    func fetchOrCreateCert(deviceUDID: String) async throws -> (certPEM: String, keyPEM: String, serial: String) {
        // listDevelopmentCertificates → 本地已有未过期则复用 → 否则 CSRGenerator + submitDevelopmentCertificate
    }
    func fetchOrCreateProfile(bundleID: String, deviceUDID: String) async throws -> ProvisioningProfileData {
        // downloadTeamProvisioningProfile → ProfileParser.parse → 校验 deviceUDIDs 包含本机
    }
}
```

- [ ] **Step 5: 推送 CI（RED→GREEN 流程同 Task 3）**

预期：CI 全绿，CSR openssl 校验 PASS，fetch-first 顺序断言 PASS。

- [ ] **Step 6: 提交 + devlog（记 Step 1 抄录的端点/字段清单）**

```bash
git add -A && git commit -m "feat(provisioning): CSR/developerservices 客户端/协调器（fetch-first）"
echo "- $(date +%F) Task4 ProvisioningEngine 完成；端点清单见 devlog" >> tools/devlog.md && git add -A && git commit --amend --no-edit
```

---

### Task 5: InstallEngine（自连 lockdownd，probe 门禁 → AFC + installation_proxy）

**Files:**
- Create: `App/Sources/Engines/Install/PairingRecord.swift`
- Create: `App/Sources/Engines/Install/LockdownClient.swift`
- Create: `App/Sources/Engines/Install/AFCClient.swift`
- Create: `App/Sources/Engines/Install/InstallationProxyClient.swift`
- Create: `App/Sources/Engines/Install/InstallCoordinator.swift`
- Create: `App/Sources/Infra/PlistFraming.swift`

**Interfaces:**
- Consumes: Task 2 `PlistCodec`/`AppLogger`；M0 pairing 文件（用户导入）
- Produces:
  - `struct PairingRecord { init(data: Data) throws; var hostID: String; var systemBUID: String; func tlsIdentity() throws -> (SecIdentity, [SecCertificate]) }`
  - `final class LockdownClient { init(pairing: PairingRecord) async throws; func request(_ dict: [String: Any]) async throws -> [String: Any]; func startService(_ name: String) async throws -> Int /* 端口 */; func close() }`
  - `final class AFCClient { init(lockdown: LockdownClient, port: Int) async throws; func uploadFile(local: URL, remotePath: String) async throws }`
  - `final class InstallationProxyClient { init(lockdown: LockdownClient, port: Int) async throws; func install(packagePath: String, progress: @Sendable (Double) -> Void) async throws }`
  - `final class InstallCoordinator { func install(ipaURL: URL, pairingData: Data, progress: @Sendable (Double) -> Void) async throws }`
  - `LockdownClient.deviceUDID() async throws -> String`（QueryUniqueDeviceID 取本机真实 UDID——Task 4 的证书/描述文件流程依赖它）
  - `enum PlistFraming { static func write(_ dict: [String: Any], to stream: OutputStream) throws; static func read(from stream: InputStream, timeout: TimeInterval) async throws -> [String: Any] }`（4 字节大端长度帧）

- [ ] **Step 1: Probe 门禁（真机，GO/NO-GO）——先探自连再写全量客户端**

最小 probe（临时并入 UI：设置页加一个「自连探测」按钮，Task 6 会移除）：

```swift
func selfConnectProbe(pairingData: Data) async -> String {
    // 1. getifaddrs 取 en0 IPv4（自身 WiFi IP）
    // 2. TCP 连接 self:62078
    // 3. TLS 握手（用配对 host 身份）
    // 4. 发 {"Request":"QueryType"} 读应答
    // 5. ValidatePair + StartSession + EnableSSLSession
    // 6. 逐步返回每步结果文本（成功值/错误原文），AppLogger 全记
}
```

协议序列参照（本地源码，只读）：`tools/spike/.venv/Lib/site-packages/pymobiledevice3/services/lockdown.py` 的 `start_session`/`validate_pair` 实现。**probe 任一步失败即停下向用户报 GO/NO-GO**（fallback 方案见计划附录 B：itms-services OTA + 本地 HTTPS + 自签 CA 信任，实现推迟到 probe 失败时再启动）。

- [ ] **Step 2: 实现 PairingRecord / PlistFraming / LockdownClient / AFCClient / InstallationProxyClient**

关键协议事实（写实现时照此，源码为准）：
- lockdownd TCP 消息 = 4 字节大端长度 + bplist payload
- 握手序：`QueryType` → `ValidatePair`(带 PairRecord=配对文件 dict) → `StartSession`(HostID+SystemBUID) → 应答含 EnableSSLSession → **此后切换 TLS**（用配对文件里 host 证书+私钥）
- `StartService`（Service=com.apple.afc / com.apple.mobile.installation_proxy）→ 应答 Port → **新开 TCP 连接**（同一 TLS 配置）跑服务协议
- AFC：version 0/848 手包 + `Command=ReadDirectory/MakeDirectory/GetFileInfo/FileClose` 文件写用 `FileRefOpen(mode=1 写)+FileTransfer` 分块；参照 `pymobiledevice3/services/afc.py`
- installation_proxy：`{"Command":"Install","PackagePath":"<afc 路径>"}` → 轮询 `{"Command":"Progress"}`，PercentComplete 字段 → `{"Command":"Finish"}`；参照 `pymobiledevice3/services/installation_proxy.py`

- [ ] **Step 3: 真机验收（用户配合）**

导入 M0 pairing 文件（App 内文件选择器），真机点「自连探测」→「安装测试」（装 Task 3 的 fixture 签名 IPA 或 Feather.ipa）。记录每步结果与耗时。
预期：probe 全绿 + 安装成功、桌面出现目标 App。

- [ ] **Step 4: 提交 + devlog（记 probe 实测数据：连接耗时、TLS 细节、失败重试参数）**

```bash
git add -A && git commit -m "feat(install): 自连 lockdown + AFC + installation_proxy 安装链"
echo "- $(date +%F) Task5 InstallEngine 完成（probe 数据见 devlog）" >> tools/devlog.md && git add -A && git commit --amend --no-edit
```

---

### Task 6: UI 装配 + 端到端真机验收 + M1 报告

**Files:**
- Create: `App/Sources/Features/Signing/SigningView.swift` + `SigningViewModel.swift`
- Create: `App/Sources/Features/Certificates/CertificatesView.swift` + `CertificatesViewModel.swift`
- Create: `App/Sources/RootTabView.swift`
- Modify: `App/Sources/LocSignApp.swift`
- Create: `docs/spike/2026-11-M1-acceptance-report.md`
- Remove: Task 5 的临时探测 UI

**Interfaces:**
- Consumes: Task 3 `SigningEngine.sign`、Task 4 `ProvisioningCoordinator`、Task 5 `InstallCoordinator`
- Produces: 可用 App；M1 验收报告

- [ ] **Step 1: UI 骨架（SwiftUI，中文文案）**

`RootTabView`：TabView 三页——「签名」「证书」「关于」。签名页：`fileImporter(.ipa)` 导入 → 显示文件名/大小 → 「签名并安装」按钮 → 进度条（签名阶段/上传阶段/安装阶段三段文案）→ 结果区。证书页：Apple ID 登录表单（账号/密码/验证码三行，验证码行仅在触发 2FA 时出现）+ 证书卡片（名称/序列号/到期倒计时天数）+ 描述文件卡片。ViewModel 全部 `@MainActor class … : ObservableObject`，错误弹 `alert` 显示 `LocalizedError.errorDescription`。

- [ ] **Step 2: 移除 Task 5 临时探测 UI，装配真实链路**

签名按钮动作 = `coordinator.signIn(如未登录) → registerAppIDIfMissing(<目标ipa的bundleID>.locsign) → fetchOrCreateCert(deviceUDID: LockdownClient.deviceUDID()) → fetchOrCreateProfile(bundleID:deviceUDID:) → SigningEngine.sign → InstallCoordinator.install`。目标 App 的 bundleID 从 IPA 的 Info.plist 读出（`IPAPacker.unpack` 后读），本机 UDID 经自连 lockdownd 查询（Task 5），AppID 命名规则：`<原bundleID>.locsign` 避免与原 App 冲突。

- [ ] **Step 3: 真机端到端验收（用户操作，助手记录）**

1. CI 下载新 `LocSign-ipa` → **关系统代理** → Sideloadly 安装 LocSign 本体 → 信任证书 → 启动。
2. App 内登录免费 Apple ID（记录 2FA 到达方式——M0 待验证项）。
3. 导入 `tools/spike/downloads/Feather.ipa` → 签名并安装 → 桌面出现 Feather（bundleID 应为 `…locsign` 后缀）→ 启动。
4. 观察：限流是否触发（Review Focus 5）、全程耗时。
**验收标准（spec §9）**：完成一次「导入→签名→安装→启动」即 M1 PASS。

- [ ] **Step 4: 写 M1 验收报告（模板：环境/步骤记录/实测数据/失败与绕行/结论 PASS-FAIL/M2 遗留），提交**

```bash
git add -A && git commit -m "feat(ui): 签名/证书页装配 + M1 端到端真机验收"
```

---

## 附录 A：ldid 构建备选链

主路径 ProcursusTeam/ldid 手工 clang++ → 其 Makefile → saurik 原版（自带 crypto）→ zsign + iOS OpenSSL（x2on/OpenSSL-for-iPhone 脚本，构建约 10 分钟）。任一替换必须：`nm` 无 `_SSL_` 外部依赖检查 + fixture 签名测试（Task 3）通过 + 记 Ruling。

## 附录 B：安装路线后备（OTA）

仅当 Task 5 probe 失败时启动：App 内嵌 GCDWebServer（HTTPS，自签 CA 首次引导用户安装并信任）→ 生成 OTA manifest plist → `itms-services://` 打开系统安装器。此路线每次安装多一步 CA 信任，体验差，故为后备。

## 附录 C：M0 报告设计输入对照

直连铁律→Task 2 DirectURLSession；解锁前置→Task 5 真机步骤注释；会话语义→M2；账号直连教训→Task 4 Client；免费账号限流→fetch-first（Review Focus 5）。
