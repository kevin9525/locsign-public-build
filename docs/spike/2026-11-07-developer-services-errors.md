# 自动申请签名材料的错误诊断

用户在配对设备验证通过后，点击“获取材料并签名”，界面显示：

`The operation couldn’t be completed. (LocSign.DeveloperServicesError error 0.)`

用户确认报错前没有出现“确认撤销开发证书”列表。这个数字是 Swift 错误桥接到 NSError 后的编号，不能当作 Apple 的 HTTP 状态或业务返回码。截图没有记录失败的具体请求，暂不能确认远端拒绝的原因，也不能据此认定证书配额已满。

## 已定位的错误信息丢失

`DeveloperServicesError` 没有实现 `LocalizedError`，因此用户只能看到系统通用文案。`XKitDeveloperServicesGateway.call` 只从 `ClientError` 中解包自己的服务错误，包装过的网络错误和取消会被错误归类为 `invalidResponse`。各请求也没有附带固定的操作名称。

0.2.2 / build 8 保留安全错误类型、HTTP 状态或 Apple 数字返回码，以及查询应用标识、注册设备、申请证书、读取和创建描述文件等步骤。错误不包含原始响应、请求头、账号或私钥内容。只有明确的证书配额错误继续触发现有精确列表确认流程；普通 HTTP 409 不被当作证书配额。嵌套请求保留更准确的失败步骤，包装后的网络错误和取消也不再归类为无效响应。

本次未改动材料申请、复用和撤销策略，也未清除账号或修改 Bundle ID。

## 验证状态

先增加 6 项回归测试，在未改生产代码的[旧实现运行](https://github.com/kevin9525/locsign-public-build/actions/runs/42350909452)中观察到 185 项测试里的 13 个失败断言，全部集中在新增的 6 项测试；原有 179 项通过。模拟器日志已保存，随后才取消旧运行并推送修复。

旧实现日志证实，HTTP 409 和证书申请的 Apple 3250 都被展示为 `DeveloperServicesError error 0`，与截图一致。这只证明错误信息丢失，不能证明用户遇到的实际返回码就是这两个测试值。

回归覆盖可读错误描述、操作步骤和 HTTP 状态、无效响应的安全展示、包装后的网络失败与取消，以及 legacy 证书申请的 Apple 业务码。修复后本地 Swift 语法解析和 4 项打包测试通过；Windows 语法解析不等于 Xcode 编译。

[修复验证运行](https://github.com/kevin9525/locsign-public-build/actions/runs/42352560129)对应公开构建源码 `5bc04b9cd5b9c9ff80274406fcd8b7a1c93cdef8`，使用 `macos-15-intel`。模拟器和设备构建、185 项 XCTest、4 项打包测试及 IPA 打包均通过；模拟器诊断产物 `13566123243` 中的日志确认 `Executed 185 tests, with 0 failures` 和 `TEST SUCCEEDED`。

最终 IPA 从产物 `13566786541` 下载，交付名为 `LocSign-0.2.2-build8-unsigned.ipa`，共 12,879,813 字节。已实际解包核验版本 `0.2.2`、构建号 `8`、主程序、三枚 Apple 根证书、第三方许可、未签名状态和 CRC。

SHA256：`78adc5d06622e7461305c5b11be96a0036eaad6721edca505535c4a1468e94ab`。

## 真机复测

通过 Sideloadly 使用原 Apple ID 和 Bundle ID 覆盖更新诊断版。保留原配对文件和当前账号，重新选择 Feather.ipa，点击“获取材料并签名”，记录完整错误中的步骤和数字返回码。错误展示修复不代表材料申请、IPA 签名、设备安装和启动已经成功；应依据下一次真机结果继续定位。
