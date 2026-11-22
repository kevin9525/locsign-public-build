# LocSign 开发日志

> 2026-11-22 补录：此前日志停在 11-04，以下按版本从 README、`docs/spike/` 记录和 `deliverables/` 使用说明回填。
> 日期取自对应记录文件；同一天多个版本按版本号排序。"真机"指机主手机实测，其余仅 CI 验证。

- 2026-11-04 Task1 工程骨架创建（XcodeGen + CI）；M0 spike 四闸门全部 PASS → GO（`docs/spike/2026-11-M0-spike-report.md`）
- 2026-11-05 接手 NB 参考流程（`feat/nb-takeover`）：签名基础链修复、设备连接探测、自连 lockdownd 安装（`2026-11-05-install-validation.md`）；0.1.3 配对 TLS 证书兼容修复
- 2026-11-06 0.1.4 无 AKI 配对证书链修复；Apple ID ProvisioningEngine 设计与计划（XKit 固定版本）
- 2026-11-07 0.2.0–0.2.6：Apple ID 登录/2FA、证书与描述文件申请复用、Feather 预检兼容、Developer Services 错误 C01–C09 诊断、可选个人签名标识、缺失证书内容恢复
- 2026-11-09 0.2.8 安装心跳；0.2.9 修复 `0xe8008017` 资源签名（embedded.mobileprovision 先写入再封资源）——**真机 Feather 安装并打开成功**；0.3.0 一键安装
- 2026-11-10 0.3.1/0.3.2 描述文件重名冲突与 P00 诊断（真机确认安装完成）；0.4.0 App 管理、到期前自动续签、固定点虚拟定位
- 2026-11-11 0.4.1 定位读取精简配对文件错误码 13 修复（**真机可定位**）；0.4.2 大陆地址 GCJ-02→WGS-84 自动转换（真机确认约 704 m 偏差基本消除）；0.4.3 无 Wi-Fi 辅助（快捷指令临时关闭蜂窝数据，实验）
- 2026-11-17 0.4.4 无 Wi-Fi 路径同连接完成查询与配对认证，L01–L07 分阶段报错；定位连接方式设计
- 2026-11-19 0.4.5 定位页记住连接方式；0.4.6 LocSign 自身到期提醒与手动自身续签
- 2026-11-20 0.4.7 权限查询格式不兼容时换只读接口核对；0.4.8 支持 App Groups 与额外内存授权的已知描述文件；0.4.9 手动续签显示待撤销证书列表；0.4.10（29）自身覆盖安装 TLS -9805/-9806 断开显示"待核验"，重开后按描述文件精确匹配确认——CI 450 XCTest / 16 原生 / 8 打包通过，**真机未验收**
- 2026-11-22 0.4.11（30）M3 打磨：新增 App 图标（`App/Resources/Assets.xcassets/AppIcon.appiconset`，单张 1024×1024 不透明 PNG）、`.ci/verify-app-icon.py` 源与 IPA 双重校验、补录本日志与各计划状态。本地 Python 打包测试 11 项通过；XCTest、设备构建与图标显示待 CI 与真机核验（`docs/spike/2026-11-22-app-icon.md`）
- 2026-11-22 0.4.11（30）支持带扩展的 IPA：PlugIns 中最多 9 个扩展，每个扩展单独注册 App ID 并申请描述文件（同证书同设备），个人签名标识下扩展随之改前缀；Zsign 多描述文件路径改为先按精确标识选定并写入描述文件、再封资源。新增预检/申请/真实签名测试与扩展 fixture。Swift 未本地编译，待 CI 与真机（`docs/spike/2026-11-22-app-extensions.md`）
- 2026-11-22 修复 CI #78 编译失败：上一提交写入 `Vendor/zsign/src/bundle.cpp` 时文件在第 496 行被截断（缺约 265 行，C++ 报 expected '}'）。已从父提交 d8c31e0 取回完整文件并重新应用 `upstream.patch` 中的嵌套描述文件改动；截断文件与重建结果的前 496 行逐字节一致。同提交其他文件检查无截断
- 2026-11-22 0.4.12（31）Apple ID 证书管理（参考 NB）：App 页与 Apple ID 设置新增"证书与 App ID 管理"，列出开发证书（标记 LocSign 使用中、可单独撤销）、App ID 与描述文件、已注册设备，并估算免费账号 7 天内剩余 App ID 额度。撤销前重读 Apple 列表，变化即停止；先失效本机材料再撤销。不删除 App ID/描述文件/设备。新增 `DeveloperAccountManagerTests`。Swift 未本地编译，待 CI 与真机（`docs/spike/2026-11-22-certificate-management.md`）
- 2026-11-22 0.4.12（31）定位收藏与最近使用：实现 11-20 先行提交测试（`6cc3292`）的功能，修复 CI #79/#80 中 `LocationViewModelTests` 两项失败。收藏可命名/重命名/删除，最近 20 次成功应用自动记录，点选只填入坐标；保存原始坐标与坐标类型；损坏数据不被覆盖，历史写入失败不影响定位结果。移植私有仓库 `LocationPlacesStoreTests` 5 项与 `LocationViewModelTests` 4 项（`docs/spike/2026-11-22-location-places.md`）
