# 0.3.2 描述文件名称与 P00 证据

## 现场与参考证据

用户在 0.3.1 交付后提供 Feather.ipa 一键安装截图，错误为“创建描述文件失败：描述文件创建冲突（P00）…HTTP 409”。P00 说明错误数组已解析，但没有匹配到现有原因类别。旧版没有保留服务端具体代码和文字，因此仍不能确认此次现场原因；账号、团队等截图内容不写入仓库。

继续调查发现独立可验证的名称问题：gateway 每次创建先使用 `LocSign <bundle resource id>`，需要更新材料时也与旧文件同名。上游 [xtool issue 426](https://github.com/xtool-org/xtool/issues/426) 记录 Apple 的实际错误句式为 `Multiple profiles found with the name '<profile>'. Please remove the duplicate profiles and try again.`，现有严格分类器不接受这一句式，因此会显示 P00。

[xtool PR 430](https://github.com/xtool-org/xtool/pull/430) 于 2026-11-06 合并，上游明确记录免费账号也支持不同名称的多个描述文件。LocSign 使用不同的新名称规避自身创建时的名称冲突，保持既有设计中不自动删除描述文件的约束。上游证据不是这台手机原始响应的替代品。

## 范围

已有缓存和远端文件仍先经过完整验证，能用就复用。只有原流程确实需要创建时，生成新的 UUID 描述文件显示名称；Bundle ID、证书、设备和类型不变。原有明确重名时的一次重试仍有相同次数与取消限制，未知原因不会新增 POST。

未知冲突增加固定、脱敏的诊断信息：已知 Apple 错误代码、已知字段以及有限的关键词提示。仅白名单枚举跨越错误边界，响应正文、账号、证书、设备值和未知代码不保留。关键词忽略引号内名称和标识符，只作为线索，不视为确定原因或重试许可。

## 验证记录

- 通过旧 API 编写失败回归：两次独立创建的名称不重复且关联一致，P00 保留已知代码与名称重复线索，live adapter 能将这些固定信息交给 UI。
- 覆盖引用名称不能伪造线索、邮件/URL/标识不泄漏、未知代码不原样保留、带线索的 P00 不增加 POST；保留全部原有取消、混合冲突和验证复用测试。
- Windows 本地执行打包测试，macOS CI 执行完整 XCTest、模拟器和设备构建；交付前核验最终 IPA 版本、应用标识、资源及 CRC。

旧实现的[失败回归 CI](https://github.com/kevin9525/locsign-public-build/actions/runs/42750134954)（源码 `c6ab132da87471aa6056fb3914b18f821c91cf07`）运行 286 项 XCTest，新增三项用例触发 6 个断言失败，原有 283 项通过。两次创建请求均使用 `LocSign bundle`，纯解析和真实 adapter 路径均丢弃了所需的固定诊断线索。失败证据对应已识别的代码缺口，并非对现场原因的断言。

只读审查未发现阻断问题；其指出的撇号歧义已修正：引用中间闭合后紧跟字母/数字或引用未闭合时，不提取任何关键词，仅保留白名单代码/字段。测试覆盖普通引号、智能引号、名称中的撇号及未闭合引用。

最终[实现 CI](https://github.com/kevin9525/locsign-public-build/actions/runs/42753288189) 的 4 项打包测试、模拟器构建、289 项 XCTest（0 失败）、设备构建及 IPA 打包全部通过。公开源码 `9b0bb40ea35dde69ae6d60a79b0c449f31b1a7b7` 对应私有实现 `b4820a2`。最终 job `129621829186` 状态 success。已下载核验未签名设备 IPA 的 `0.3.2（18）`、原应用标识 `com.locsign.LocSign`、必需证书/许可资源、可执行文件及 ZIP CRC。文件大小 13,019,023 字节，SHA-256：`4ba8efd86a52d11e02d3272a5c656eb1ccffebf1f4a7a7a66b87aefda1ae6055`。实际 Feather 安装结果仍需真机确认。

## 真机复测

使用原 Apple ID 与 LocSign 应用标识覆盖安装 0.3.2（18），保持原团队、Feather 个人标识和配对设置。开启 LocalDevVPN，选择原 Feather.ipa 并点击“一键安装”。若仍失败，提供完整错误，包括 P00 后新增的固定诊断信息；若成功，确认安装完成后能打开 Feather。此轮真机结果待用户反馈。
