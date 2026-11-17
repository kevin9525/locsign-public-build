# Reuse the assisted location connection

The user confirmed a `连接设备服务失败（61）` error after selecting **无 Wi-Fi 应用定位** on installed 0.4.3 (22), with LocalDevVPN enabled. USB confirmed the version. The previous live-log output included ordinary system connection events but did not establish which LocSign socket failed. Do not treat these system events as proof of a specific VPN or TLS failure.

The 0.4.3 path probes QueryType through Network.framework, closes that probe, then immediately opens a different POSIX socket for pairing. Its readiness result therefore does not cover the transport actually used by location. Raw socket failures from either the control port or heartbeat port also lack a location-stage prefix. This is a code-level gap, not a confirmed explanation of every cellular refusal.

0.4.4 (23) reserves a POSIX control connection during assisted readiness and passes that exact connection into QueryType, StartSession and pairing TLS. It does not bypass authentication. A short TCP-connect deadline is separate from the normal eight-second per-I/O timeout, so the readiness polling timeout is not reused for TLS. Host changes, cancellation, explicit disconnect and failed authentication close any reserved connection. Literal IP addresses keep DNS blocking outside this readiness path.

Errors distinguish L00 (pairing parse), L01 (control port 62078), L02 (pairing authentication), L03 (location certificate), L04 (device identity), L05 (start heartbeat), L06 (heartbeat port) and L07 (heartbeat response). Native developer-image/tunnel errors keep their existing operation labels. No raw credentials, coordinates or device identifiers are logged or published.

Tests cover actual controller reuse through TLS, heartbeat-port failure classification, changed-host disposal, disconnect during pending preparation, and a loopback socket whose delayed response exceeds the short connection deadline but remains within its I/O deadline. The heartbeat connection retains its separate 30-second default timeout, because a heartbeat request can arrive after 15 seconds. Cellular operation and continued positioning after data restoration still require a device result; the existence of this build is not a claim that LocalDevVPN's cellular routing has been fixed.

## Verified delivery

GitHub Actions run [44008772161](https://github.com/kevin9525/locsign-public-build/actions/runs/44008772161) completed successfully for public source `16624c9d9c4ea4d2ca1d07b8682125270996d3b4`. The downloaded job log confirms 399 XCTest cases with zero failures, two native test groups with 10 and 6 passes respectively, and 8 packaging tests. The simulator and unsigned arm64 device builds succeeded.

Artifact `14296733725` contains `LocSign-0.4.4-build23-unsigned.ipa` (24,789,921 bytes), SHA-256 `2470dee8810d9a9e53097047711af90b6c1e29d5bc498386865cdb48ca60efec`. Local verification checked ZIP CRC, version/build, bundle identity, arm64 executable, unsigned packaging, callback scheme, background processing mode, certificate/license resources and all three developer-image resource hashes. The IPA, verification JSON and Chinese instructions were placed in the user's designated deliverables directory.

The last USB version check still showed 0.4.3 (22). Version 0.4.4 (23) has not yet been signed, installed or verified on that phone. The existing two cellular-data shortcuts can be reused for the device test.
