# 无签发者密钥标识的 Apple 配对证书

## 真机证据

用户报告 LocSign 0.1.3 的“配对认证未通过：配对 TLS 握手或设备证书验证失败（-9807）：设备证书校验未通过：self-signed certificate”。

通过现有 USB 配对会话直接读取目标 iPhone 15 Pro Max 返回的 TLS 证书，确认：

- 实际安装的是 0.1.3，手机中的五字段配对文件与电脑现有记录完全一致。
- TLS 对端只发送一个设备证书，与配对记录里的 DeviceCertificate 相同；签名能由 RootCertificate 公钥验证。
- 设备证书为 RSA-2048 / SHA-1，subject 和 issuer 均为空，仅有 Basic Constraints、Subject Key Identifier、Key Usage 三种扩展，没有 Authority Key Identifier（AKI）。
- 将当前验证参数应用于真实证书，OpenSSL 返回 18 / self-signed certificate；`X509_self_signed(cert, 0)` 返回 1，而真正验证自签名的 `X509_self_signed(cert, 1)` 返回 0。

这些检查在本机内存中完成，没有把真实配对证书或私钥保存到项目、提交或上传。

## 前一轮测试遗漏

0.1.3 的合成证书包含 OpenSSL 自动生成的 AKI，而真实 Apple 配对证书没有。OpenSSL 的链构造使用名称和 AKI 判断自签名；在两个名称均为空且没有 AKI 时，会提前把叶证书当作自签名证书，拒绝寻找真正签发它的配对根。之前成功的空主体测试没有覆盖这一特征。

`.ci/generate-legacy-pairing-fixtures.py` 显式禁用 AKI，添加真实 TLS 往返，以及错误空名称根、过期/尚未生效、签名损坏、过期根、未知关键扩展和 CA 叶证书的回归样本。所有样本均为独立生成的公开测试材料。

## 修复约束

保留常规链验证。仅当链构造报告深度零自签名错误且证书符合受限的 Apple 配对格式时，显式验证设备证书的根签名和签发约束，验证根自身的签名与有效期，再验证设备证书有效期和扩展。不会无条件忽略错误，也不会信任对端提供的根。配对文件格式不变。

兼容分支仅接受空主体/签发者名称、缺少叶 AKI、明确 root CA / leaf 非 CA 的直接配对结构，扩展限于 Basic Constraints、Subject Key Identifier、Key Usage，以及根可选 AKI；不支持的扩展一律拒绝，防止分开校验时丢失名称限制或 EKU 等约束。通过 `X509_check_issued` 和实际签名证明后，根仍执行完整校验（含自签名），精确叶证书仅在临时 store 中以 PARTIAL_CHAIN 检查有效期/扩展。

## 验证证据

- 测试提交 `63f9d0e` 的 [CI 42140128535](https://github.com/kevin9525/locsign/actions/runs/42140128535) 执行 61 项 XCTest，唯一失败为新加的无 AKI 正常配对测试，精确复现 `-9807` 和底层 error 18 / self-signed certificate。
- 本机通过内存中的真实 DeviceCertificate 和 RootCertificate 调用 OpenSSL，确认 issuer 检查与签名验证成功；两者密钥安全强度为 112 bit，根完整校验和证明签名后的叶有效性检查均通过。该检查用于验证修复原理，不能代替 iOS 编译或手机 TLS 验收。

- 修复提交 `077d712` 的 [CI 42140777649](https://github.com/kevin9525/locsign/actions/runs/42140777649) 全部通过：61 项 XCTest、4 项 Python 打包测试，以及 Release iPhone 未签名构建和 IPA 打包（0.1.4 / build 5）。新增负例严格检查错误码，避免仅因链构建 error 18 而假通过。
- 独立只读审阅 `3acf5ee..077d712` 未发现 Critical / Important 问题；另用本机 libcrypto 验证八种样本的结果，并在内存破坏根自签名，确认拒绝。记录一项非阻塞测试建议：后续补根的 nameConstraints/EKU、缺少 keyCertSign 以及损坏根自签名的自动回归例。
- 已下载并核对 `LocSign-0.1.4-077d712-unsigned.ipa`：版本 0.1.4 / build 5，文件共享启用，IPA 校验完整，可执行文件存在。SHA-256：`e35607e7234609103b8fc83985a463295373fd0d6d2f7c5676479189585c661d`。

## 真机复测结果

2026-11-06，交付 0.1.4 并请用户经 LocalDevVPN 重新执行“验证配对与安装服务”后，用户反馈“都正常了”。按该检测的范围记录为：iPhone 15 Pro Max / iOS 18.7.8 的配对 TLS 认证、AFC 服务连接、installation_proxy 服务连接通过。本结论来自用户真机反馈，不是助手直接操作手机观察，也不是仅依据电脑 USB 认证或 CI 推断。

本轮 `-9807 / self-signed certificate` 故障已获用户真机复测确认。现有配对文件可继续使用，无需重新生成。该检查没有上传 IPA 或发送 Install 命令，因此真实安装接受结果、应用启动仍未验收。用户目前没有 P12/mobileprovision；下一步需接入免费 Apple ID 认证和证书/描述文件申请，再推进完整签名安装验收。
