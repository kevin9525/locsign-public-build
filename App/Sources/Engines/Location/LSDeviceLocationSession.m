#import "LSDeviceLocationSession.h"
#import <CommonCrypto/CommonDigest.h>
@import IDevice;
#include <arpa/inet.h>
#include <math.h>

static BOOL LSLocationError(NSError **error, NSString *message, NSInteger code) {
    if (error) *error = [NSError errorWithDomain:@"LocSign.Location" code:code
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

static BOOL LSLocationAccept(struct IdeviceFfiError *failure, NSString *operation, NSError **error) {
    if (!failure) return YES;
    NSInteger code = failure->code;
    idevice_error_free(failure);
    // Upstream debug messages can include device identifiers and protocol payloads.
    return LSLocationError(error, [NSString stringWithFormat:@"%@失败（错误码 %ld）。请确认开发者模式和 LocalDevVPN 已开启，并检查网络连接。", operation, (long)code], code);
}

static BOOL LSLocationReadPairing(NSData *data, struct IdevicePairingFile **pairing, NSError **error) {
    if (!data.length || data.length > 1024 * 1024) {
        return LSLocationError(error, @"配对文件为空或过大，请重新导入。", -2);
    }
    struct IdeviceFfiError *failure = idevice_pairing_file_from_bytes(data.bytes, data.length, pairing);
    if (!failure) return YES;
    NSInteger code = failure->code;
    idevice_error_free(failure);
    return LSLocationError(error, [NSString stringWithFormat:
        @"定位模块无法解析配对文件（错误码 %ld）。请更新 LocSign 后重试；此步骤尚未连接开发者服务。", (long)code], code);
}

static NSData *LSLocationImage(NSURL *directory, NSString *name, NSUInteger expectedSize,
                             NSString *expectedDigest, NSError **error) {
    if (!directory) {
        LSLocationError(error, @"安装包缺少开发者镜像。请更新 LocSign，或先通过电脑挂载适用于 iOS 18 的开发者镜像后重试。", -20);
        return nil;
    }
    NSURL *url = [directory URLByAppendingPathComponent:name];
    NSNumber *size = nil;
    if (![url getResourceValue:&size forKey:NSURLFileSizeKey error:error] || size.unsignedLongLongValue != expectedSize) {
        LSLocationError(error, @"开发者镜像文件缺失或大小不符，请重新安装完整安装包。", -21);
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:error];
    if (!data || data.length != expectedSize) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *actual = [NSMutableString stringWithCapacity:64];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [actual appendFormat:@"%02x", digest[i]];
    if (![actual isEqualToString:expectedDigest]) {
        LSLocationError(error, @"开发者镜像校验失败，请重新安装完整安装包。", -22);
        return nil;
    }
    return data;
}

@implementation LSDeviceLocationSession {
    NSThread *_owner;
    struct IdeviceProviderHandle *_provider;
    struct AdapterHandle *_adapter;
    struct RsdHandshakeHandle *_handshake;
    struct RemoteServerHandle *_server;
    struct LocationSimulationHandle *_location;
}

+ (BOOL)validatePairingData:(NSData *)pairingData error:(NSError **)error {
    struct IdevicePairingFile *pairing = NULL;
    BOOL accepted = LSLocationReadPairing(pairingData, &pairing, error);
    if (pairing) idevice_pairing_file_free(pairing);
    return accepted;
}

- (instancetype)initWithHost:(NSString *)host pairingData:(NSData *)pairingData
                ddiDirectory:(NSURL *)ddiDirectory error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    _owner = NSThread.currentThread;
    struct sockaddr_storage storage = {0};
    struct sockaddr_in *v4 = (struct sockaddr_in *)&storage;
    struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)&storage;
    if (inet_pton(AF_INET, host.UTF8String, &v4->sin_addr) == 1) {
        v4->sin_family = AF_INET; v4->sin_len = sizeof(*v4); v4->sin_port = htons(62078);
    } else if (inet_pton(AF_INET6, host.UTF8String, &v6->sin6_addr) == 1) {
        v6->sin6_family = AF_INET6; v6->sin6_len = sizeof(*v6); v6->sin6_port = htons(62078);
    } else {
        LSLocationError(error, @"定位连接需要有效的设备 IP 地址。", -1); return nil;
    }
    struct IdevicePairingFile *pairing = NULL;
    if (!LSLocationReadPairing(pairingData, &pairing, error)) return nil;
    struct IdeviceFfiError *failure = idevice_tcp_provider_new((struct sockaddr *)&storage, pairing, "LocSign", &_provider);
    if (failure) { idevice_pairing_file_free(pairing); LSLocationAccept(failure, @"创建设备连接", error); return nil; }
    // Pairing ownership transferred into provider on success.
    if (![self prepareImage:ddiDirectory error:error] || ![self connectLocation:error]) { [self close]; return nil; }
    return self;
}

- (BOOL)prepareImage:(NSURL *)directory error:(NSError **)error {
    struct ImageMounterHandle *mounter = NULL;
    struct LockdowndClientHandle *lockdown = NULL;
    struct IdevicePairingFile *pairing = NULL;
    plist_t chipValue = NULL;
    @try {
        if (!LSLocationAccept(image_mounter_connect(_provider, &mounter), @"连接开发者镜像服务", error)) return NO;
        // Upstream requires a queried lockdown connection AFTER image-mounter connect.
        if (!LSLocationAccept(lockdownd_connect(_provider, &lockdown), @"连接设备", error)) return NO;
        if (!LSLocationAccept(idevice_provider_get_pairing_file(_provider, &pairing), @"读取配对身份", error)) return NO;
        if (!LSLocationAccept(lockdownd_start_session(lockdown, pairing), @"认证设备", error)) return NO;
        if (!LSLocationAccept(lockdownd_get_value(lockdown, "UniqueChipID", NULL, &chipValue), @"读取设备芯片标识", error)) return NO;
        if (plist_get_node_type(chipValue) != PLIST_UINT) return LSLocationError(error, @"设备未返回有效芯片标识。", -3);
        uint64_t chipID = 0;
        plist_get_uint_val(chipValue, &chipID);
        int enabled = 0;
        if (!LSLocationAccept(image_mounter_query_developer_mode_status(mounter, &enabled), @"检查开发者模式", error)) return NO;
        if (!enabled) return LSLocationError(error, @"请先在 设置 → 隐私与安全性 → 开发者模式 中开启并重启设备。", -4);
        uint8_t *signature = NULL;
        size_t signatureLength = 0;
        struct IdeviceFfiError *lookup = image_mounter_lookup_image(mounter, "Personalized", &signature, &signatureLength);
        if (!lookup) {
            idevice_data_free(signature, signatureLength);
            if (signatureLength) return YES;
        } else {
            // Only a known 'no image' response permits automatic mounting.
            BOOL missing = lookup->code == 20; // IdeviceError::NotFound in pinned v0.1.68.
            if (!missing) return LSLocationAccept(lookup, @"检查开发者镜像", error);
            idevice_error_free(lookup);
        }
        NSData *image = LSLocationImage(directory, @"Image.dmg", 9685392, @"a3ae9b9468f622ae01ab9415300c674a2ebf67b7f92d7d117392dea4ba452ab8", error);
        if (!image) return NO;
        NSData *trustcache = LSLocationImage(directory, @"Image.dmg.trustcache", 1059, @"8a95d27ca915b3c839227180f1028088f6dc40cdadafb3307e733f65c7f2e099", error);
        if (!trustcache) return NO;
        NSData *manifest = LSLocationImage(directory, @"BuildManifest.plist", 1428695, @"7fd2559e871556d3d09891ffb0e5d28dab5a1ffa57f8c3e7192de5651be3bc97", error);
        if (!manifest) return NO;
        return LSLocationAccept(image_mounter_mount_personalized(mounter, _provider,
            image.bytes, image.length, trustcache.bytes, trustcache.length,
            manifest.bytes, manifest.length, NULL, chipID), @"挂载开发者镜像（需要联网完成 Apple 个性化签名）", error);
    } @finally {
        if (chipValue) plist_free(chipValue);
        if (pairing) idevice_pairing_file_free(pairing);
        if (lockdown) lockdownd_client_free(lockdown);
        if (mounter) image_mounter_free(mounter);
    }
}

- (BOOL)connectLocation:(NSError **)error {
    struct CoreDeviceProxyHandle *proxy = NULL;
    if (!LSLocationAccept(core_device_proxy_connect(_provider, &proxy), @"建立设备隧道", error)) return NO;
    uint16_t port = 0;
    if (!LSLocationAccept(core_device_proxy_get_server_rsd_port(proxy, &port), @"查询开发者服务", error)) { core_device_proxy_free(proxy); return NO; }
    // Consumes proxy even when adapter creation fails.
    if (!LSLocationAccept(core_device_proxy_create_tcp_adapter(proxy, &_adapter), @"建立隧道网络", error)) return NO;
    struct ReadWriteOpaque *stream = NULL;
    if (!LSLocationAccept(adapter_connect(_adapter, port, &stream), @"连接开发者服务", error)) return NO;
    // Consumes stream on success and failure.
    if (!LSLocationAccept(rsd_handshake_new(stream, &_handshake), @"发现开发者服务", error)) return NO;
    if (!LSLocationAccept(remote_server_connect_rsd(_adapter, _handshake, &_server), @"连接定位服务", error)) return NO;
    return LSLocationAccept(location_simulation_new(_server, &_location), @"开启定位通道", error);
}

- (BOOL)applyLatitude:(double)latitude longitude:(double)longitude error:(NSError **)error {
    NSAssert(NSThread.currentThread == _owner, @"Location FFI crossed threads");
    if (!isfinite(latitude) || !isfinite(longitude) || fabs(latitude) > 90 || fabs(longitude) > 180)
        return LSLocationError(error, @"纬度须在 -90 到 90，经度须在 -180 到 180 之间。", -5);
    if (!_location) return LSLocationError(error, @"定位连接已断开，请重新连接。", -6);
    return LSLocationAccept(location_simulation_set(_location, latitude, longitude), @"应用定位", error);
}

- (BOOL)restoreWithError:(NSError **)error {
    NSAssert(NSThread.currentThread == _owner, @"Location FFI crossed threads");
    if (!_location) return LSLocationError(error, @"定位连接已断开，尚未确认恢复真实位置。", -6);
    return LSLocationAccept(location_simulation_clear(_location), @"恢复真实定位", error);
}

- (void)close {
    NSAssert(NSThread.currentThread == _owner, @"Location FFI crossed threads");
    if (_location) { location_simulation_free(_location); _location = NULL; }
    if (_server) { remote_server_free(_server); _server = NULL; }
    if (_handshake) { rsd_handshake_free(_handshake); _handshake = NULL; }
    if (_adapter) {
        struct IdeviceFfiError *failure = adapter_close(_adapter);
        if (failure) idevice_error_free(failure);
        adapter_free(_adapter); _adapter = NULL;
    }
    if (_provider) { idevice_provider_free(_provider); _provider = NULL; }
}

- (void)dealloc { [self close]; }
@end
