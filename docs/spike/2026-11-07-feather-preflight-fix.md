# Feather IPA 签名容器兼容修复

用户在 Apple ID 登录成功后，为 `Feather.ipa` 自动申请签名材料时收到“当前 IPA 不支持自动申请材料：代码签名容器无效”。用户原文件的版本和字节尚未取得，以下检查使用官方 Feather v2.9.0 作为对照。

## 对照证据与根因

官方发行页：https://github.com/claration/feather/releases/tag/v2.9.0

对照 IPA 的 SHA256 为 `833c57d3c4bf4b4a9fe408be72e1c720cbb949f736a00286750f50e7915730ea`。归档 CRC 正常，只有一个主 App，无扩展或嵌套 App，主程序是未加密的 thin arm64，Bundle ID 为 `thewonderofyou.Feather`。

主程序的 `LC_CODE_SIGNATURE.datasize` 为 186,336 字节，内部 SuperBlob 声明长度为 168,327 字节，剩余 18,009 字节均为零。三个子区块均位于逻辑容器内，无 entitlement slot。原预检查要求逻辑长度与预留区长度完全相等，因此错误拒绝了这种输入。Apple XNU 的 `cs_validate_blob` / `cs_validate_csblob` 允许逻辑长度小于可用预留区，并按逻辑长度限制内部读取。

## 修复边界

`ProvisioningIPAPreflight.inspectSignature` 接受不超过预留区的有效 SuperBlob 长度；后续索引、子区块和权限检查统一使用该逻辑长度。索引或子区块不能进入填充区；不支持的权限仍明确拒绝。此改动不改变现有单主 App、thin arm64、未加密及权限支持范围，也不改变证书和描述文件的验证。

## 回归证据

先仅加入回归测试，保留旧生产代码：[RED 运行](https://github.com/kevin9525/locsign-public-build/actions/runs/42340728730) 的模拟器测试实际执行 179 项、失败 2 项，均命中“代码签名容器无效”；该整轮之后被取消，测试日志已先保存。

再应用修复：[GREEN 运行](https://github.com/kevin9525/locsign-public-build/actions/runs/42341907147) 的 179 项 XCTest 全部通过，4 项 Python 打包测试、模拟器及设备构建均通过。新增测试覆盖有效填充、填充区中的越界索引/子区块及填充不能掩盖不支持的权限。

交付校验随后发现 App 的版本仍为 0.2.0 / build 6：`project.yml` 的目标 Info.plist 属性使用了独立常量，覆盖全局版本。已改为引用 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`，避免两个配置源再次漂移。版本配置调整后的首次验证遇到模拟器启动超时：日志没有任何测试用例结果，测试步骤被原 15 分钟上限终止。测试上限调整为 25 分钟、整轮上限为 60 分钟后，重新执行完整验证。

[最终验证运行](https://github.com/kevin9525/locsign-public-build/actions/runs/42346306254) 的 179 项 XCTest、4 项打包测试、模拟器及设备构建均通过，已生成最终 IPA。实际下载包通过 0.2.1 / build 7 版本、资源和 CRC 校验，未对包进行本地重命名以外的修改。

交付文件为 `LocSign-0.2.1-build7-unsigned.ipa`，12,877,489 字节，SHA256 为 `b9575737ea1f33826681c0989eab64def502ee7ef0c538902d6020368d9f72f5`。签名修复对应私有提交 `a99d6a4`，版本配置修正为 `6c7c6da`；最终公开构建源为 `043a7b5`，对应私有 `f2ced20`。

## 真机待验收

使用原 Apple ID 和 Bundle ID，通过 Sideloadly 覆盖安装 0.2.1 / build 7，保留账号和配对资料，再选用户原有 Feather.ipa 重试材料申请、签名、安装及启动。登录成功已由用户确认，后续真机结果仍待记录。
