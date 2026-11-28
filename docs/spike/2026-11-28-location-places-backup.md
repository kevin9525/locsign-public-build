# 收藏管理与备份（0.5.6 / build 38）

## 已确认范围

“常用地点”新增“管理”入口，支持按名称搜索、按原收藏顺序或名称排列，并保留选点、重命名和删除能力。筛选和排序只影响显示；导出包含全部收藏。

备份为带 `format: LocSign.favorites`、`version: 1` 的 JSON。每条只包含名称、原始纬经度、坐标类型及地图区域，不导出内部 UUID 或最近使用。读取上限 2 MiB、5000 条，合并后收藏也不能超过 5000 条；超限整份拒绝，已有收藏不被部分修改。旧的本地存储格式保持兼容。

导入先校验全部记录并展示新增与重复数量，用户确认后一次写入。相同原始经纬度和坐标类型视为重复，保留本地记录；备份内部重复保留第一条，不按显示精度合并。同名不同坐标、相同数字不同坐标类型均独立保留。新增记录使用新 UUID。

预览阶段不写入。确认前收藏变化时拒绝过期预览，要求重新读取；最近使用变化不影响预览，确认写入时保留最新历史。应用/恢复定位或共享设备操作期间拒绝导入。导入本身不选点或发送定位请求；选点之后仍需点击“应用定位”。

## 实现与测试

- `LocationPlacesBackup.swift`：独立格式、校验、文件读取边界。
- `LocationPlacesStore.swift`：搜索排序、导出、无副作用的合并预览、确认提交。
- `LocationViewModel.swift`：设备操作互斥与导入入口。
- `LocationPlacesManagementView.swift`：管理列表、文件导入导出、确认预览。
- `LocationPlacesBackupTests.swift`：真实 JSON 往返、坐标类型、去重、空文件、损坏内容、超限、过期预览、历史保留、搜索排序、文件读取与取消。
- `LocationViewModelTests.swift`：导入不改变当前选点/请求设备，定位与共享锁期间不导入。

## 验证进度

基线 `153e243`（已验证的 0.5.5 / 37）。首轮测试与接口 scaffold 为 `bc8ab06`，[CI #94](https://github.com/kevin9525/locsign-public-build/actions/runs/46123958669) 执行 559 项 XCTest、14 个失败记录均来自新增功能缺失（包括 scaffold 抛出的 invalidData）；既有 547 项通过。模拟器编译通过。

本地 `python -m unittest discover -s Tests/BuildTools -v`：15 项通过；`git diff --check` 通过。

完整实现 `3a977d002dba33d1e285f98ec0c5da417a001b02` 通过 [CI #95](https://github.com/kevin9525/locsign-public-build/actions/runs/46127238647)：560 项 XCTest、16 项原生测试、15 项 Python 打包测试、模拟器及设备构建、IPA 打包和图标检查全部成功。新增 11 项备份/管理测试及 2 项 ViewModel 导入测试通过。与 build 37 的测试构建日志比较无新增警告；已有第三方宏、AppIntents 和测试未使用返回值警告保留。

独立只读审查覆盖 `153e243..3a977d0`，未发现 Critical / Important 问题：确认了全部校验后预览、一次合并、原始坐标和类型去重、过期预览保护、最新历史保留、两阶段设备锁校验、有界读取和取消传播，以及全部收藏导出和记录 ID 隔离。Swift 编译和 XCTest 结论以 [CI #95](https://github.com/kevin9525/locsign-public-build/actions/runs/46127238647) 为准。

## 交付核验

- 文件：`LocSign-0.5.6-build38-unsigned.ipa`，25,950,966 字节。
- IPA SHA-256：`41e8935e199d79c203397b6335567b27f259f8e2d7ad030e6d128d30d265f425`。
- GitHub artifact：`15256209191`；外层 SHA-256：`6c23acaecbf58089da44de24a0298d9b0c274b302bd01519a94d9d3f990b73c6`，与 GitHub 公布摘要一致。
- 本地检查：版本 0.5.6 / 38、`com.locsign.LocSign`、arm64、未签名、图标、三根 Apple 根证书、许可文件、文件共享、URL scheme、后台 processing、LocationDDI 三份资源摘要及内外 ZIP CRC 全部通过。
- [草稿 PR #5](https://github.com/kevin9525/locsign-public-build/pull/5)，base 为 `feat/ipa-import-preview`，保持独立开发分支，未合并主分支。
- 本次未把 IPA 传入手机或执行安装；下列真机步骤待验收。

## 真机验收

1. 覆盖更新后，确认原收藏和最近使用保留；进入“常用地点 → 管理”。
2. 搜索名称、切换排序，确认返回主页面的收藏顺序不变。选点只填坐标，未点击“应用定位”时设备不变化。
3. 导出全部收藏到“文件”，再导入同一份备份，预览应全部标为重复，本地名称和顺序保留。
4. 导入另一份含新地点的备份，核对新增/重复数；取消确认时列表不变化，确认后重启仍保留新增收藏。
5. 核对 WGS-84、GCJ-02 和地图区域完整恢复；同一组数字不同坐标类型不合并。
6. 选择损坏、未知版本、缺坐标类型和超限备份，应提示原因且不改原数据。
7. 应用/恢复定位期间不允许导入；读取时取消或离开管理页，不得出现迟到的导入弹窗。

真机布局、文件提供方和实际定位验收尚未执行，云端测试不能代替这些检查。
