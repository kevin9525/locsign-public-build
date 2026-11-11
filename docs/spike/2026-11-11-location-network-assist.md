# Location without a Wi-Fi connection: experimental network assist

The user reproduced device connection refusal (61) and probe timeout with Wi-Fi off and LocalDevVPN enabled, while joining Wi-Fi restored connectivity. USB checks confirmed that the existing pairing, AFC, installation service, and wireless-lockdown setting work. These checks do not establish the cause of the cellular route failure.

LocalDevVPN swaps the source and destination IPv4 addresses on its local tunnel. Its VPN-connected state alone does not establish device-service reachability. SideStore's cellular refresh implementation temporarily disables cellular data using Shortcuts. This is evidence for a compatibility workaround, not proof of continuous cellular support or proof that the same path works on this iPhone.

LocSign 0.4.3 (22) adds explicit experimental buttons under Location → No Wi-Fi assist. Create two iOS shortcuts named `LocSign关闭蜂窝数据` and `LocSign开启蜂窝数据`, each with one Set Cellular Data action set to Off or On respectively. There is no Open App action; the x-callback URL returns to LocSign. The user must enable LocalDevVPN first. Prepare the developer image over Wi-Fi before this flow; a device restart may require preparation again.

The assistant flow disconnects an old location session, persists a recovery marker, waits for the disable shortcut's unique success callback, and polls QueryType with bounded per-attempt deadlines for up to 15 seconds. Only a real device-service response allows authentication and the native location operation. Completion, error and cancellation all attempt data restoration outside the cancelled operation. An unconfirmed restore remains visible and survives relaunch. Shortcut URL-launch acknowledgement is never treated as completion. If a shortcut times out, finish or stop any still-running shortcut before manually retrying recovery; a very late system action cannot be cancelled by LocSign.

Existing Wi-Fi buttons remain available. The assist may temporarily interrupt internet access, and restoring cellular data may break the location session. Accepted coordinates, connection lifetime, and actual location in another app must be verified separately. This build must not be described as a confirmed fix for cellular-only positioning until it passes device verification.

Tests cover readiness delay/timeout, restoration after device errors or cancellation, recovery persistence, shortcut acknowledgement versus callback, stale callbacks, and view-model integration with coordinate conversion. iOS compilation and device verification are recorded separately after execution; Windows cannot run XCTest.

References inspected:
- https://github.com/jkcoxson/LocalDevVPN/blob/main/TunnelProv/PacketTunnelProvider.swift
- https://github.com/SideStore/SideStore/blob/0dd743f7/SideStore/Core/Shortcuts/CellularRefreshManager.swift
- https://github.com/SideStore/SideStore/issues/1505

The implementation is independent and does not copy SideStore source. No real pairing records, identifiers, certificates or raw device logs are included.
