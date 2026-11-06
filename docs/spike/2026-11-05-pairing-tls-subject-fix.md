# Apple 配对证书空主体名称兼容修复

后续真机复测出现 `-9807 / self-signed certificate`：本轮合成样本被 OpenSSL 自动加入 AKI，与实际配对格式仍有差异。0.1.4 已补齐并修复，见 [2026-11-06 记录](2026-11-06-pairing-chain-fix.md)。下文为 0.1.3 的历史证据，不代表真机配对已成功。

## 真机问题与根因

用户在 iPhone 15 Pro Max / iOS 18.7.8 的 LocSign 0.1.2 中，经 LocalDevVPN 点击“验证配对与安装服务”，收到“配对认证未通过：TLS 握手或设备证书验证失败（-67655）”。连接检测已通过。

Apple 的 `SecBase.h` 将 `-67655` 定义为 `errSecInvalidSubjectName`。本机现有配对记录中的设备、主机、根证书均为 RSA-2048、SHA-1、序列号 0、空 issuer 和空 subject；设备和主机证书的签名均能用配对根验证，有效期为十年。没有重新配对或修改 Apple 的原记录。

原先采用 `SecPolicyCreateBasicX509` 避免网站证书的寿命限制，但 Apple 的基础策略仍包含 `kSecPolicyCheckNonEmptySubject`，会拒绝这种真实配对证书。来源：

- [Apple SecBase.h](https://github.com/apple-oss-distributions/Security/blob/main/base/SecBase.h)
- [Apple SecPolicy.c](https://github.com/apple-oss-distributions/Security/blob/main/OSX/sec/Security/SecPolicy.c)

## 修复范围

0.1.3（build 4）继续使用 SecureTransport 执行 TLS 握手和加密收发，在服务端证书检查回调中使用项目已有的 OpenSSL 校验证书链：

- 新建独立的 X509 trust store，只加入用户导入配对记录中的根，不加载系统 CA，不访问网络。
- 允许 Apple 配对格式的空名称、序列号 0、SHA-1 签名；明确要求公钥安全强度至少 112 bit，非 SHA-1 的签名也必须达到 112 bit。
- 保留证书签名、有效期、CA 约束、CA 密钥用途和关键扩展检查，同时检查根的自签名。没有采用无条件接受、忽略所有错误或系统信任例外。
- 校验失败时保留可读原因和底层验证错误，便于区分过期、签名无效与错误根。

配对文件格式无需变化；现有的 `iPhone15ProMax-pairing.plist` 可继续使用。真实私钥、证书和配对记录均未进入源码或 CI。

## 回归证据

`.ci/generate-pairing-tls-fixtures.py` 生成独立的合成根与设备密钥，模拟相同证书格式，并生成过期和签名损坏变体。测试通过真实本地 TCP/TLS 通信及加密 ping/pong 检查行为。

仅加测试的提交 `947bb13` 在 [CI 42041009663](https://github.com/kevin9525/locsign/actions/runs/42041009663) 执行 53 项 XCTest：52 项成功，唯一失败为 `testTLSAcceptsApplePairingCertificatesWithEmptySubject`，错误码精确复现 `-67655`。

修复提交 `576e7fa` 的 [CI 42045976984](https://github.com/kevin9525/locsign/actions/runs/42045976984) 全部成功：53 项 XCTest、4 项 Python 打包测试、Release iPhone 未签名构建和 IPA 打包。新增负向测试确认错误根被拒绝、过期对应 `X509_V_ERR_CERT_HAS_EXPIRED`、签名损坏对应 `X509_V_ERR_CERT_SIGNATURE_FAILURE`，避免它们仅因旧的主体格式错误而通过。

独立只读审阅覆盖 `ac63b02..576e7fa`，未发现 Critical / Important / Minor 问题；复核信任锚与对端证书的隔离、算法要求、内存释放顺序和负向测试，并独立用 OpenSSL 验证合成证书的正常及错误行为。此结论不代替真机验收。

## 手机复验

用相同 Sideloadly Apple ID 和 Bundle ID 覆盖更新到 0.1.3，保持 LocalDevVPN 开启、手机解锁，在“连接”页面选择已有配对文件，再点击“验证配对与安装服务”。需要记录手机实际结果；CI 修复不代替这一步。签名材料获取、IPA 实际安装和定位不属于本次修复。
