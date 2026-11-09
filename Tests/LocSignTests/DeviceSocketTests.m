#import <XCTest/XCTest.h>
#import <Security/SecureTransport.h>
#import <arpa/inet.h>
#import <errno.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>
#import "../../App/Sources/Engines/Install/DeviceSocket.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

typedef struct {
    int fd;
    BOOL fragmentWrites;
} LSTestPeer;

static OSStatus LSTestRead(SSLConnectionRef connection, void *data, size_t *length) {
    LSTestPeer *peer = (LSTestPeer *)connection;
    size_t requested = *length;
    size_t total = 0;
    while (total < requested) {
        ssize_t count = recv(peer->fd, (uint8_t *)data + total, requested - total, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { *length = total; return errSecIO; }
        total += (size_t)count;
    }
    *length = total;
    return noErr;
}

static OSStatus LSTestWrite(SSLConnectionRef connection, const void *data, size_t *length) {
    LSTestPeer *peer = (LSTestPeer *)connection;
    size_t requested = *length;
    size_t total = 0;
    while (total < requested) {
        size_t chunk = peer->fragmentWrites && total < 5 ? 1 : requested - total;
        ssize_t count = send(peer->fd, (const uint8_t *)data + total, chunk, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { *length = total; return errSecIO; }
        total += (size_t)count;
        // Deliberately separate TLS header bytes across TCP reads.
        if (peer->fragmentWrites && total <= 5) usleep(5000);
    }
    *length = total;
    return noErr;
}

@interface DeviceSocketTests : XCTestCase
@end

@implementation DeviceSocketTests

- (int)listenerWithPort:(uint16_t *)port {
    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) return -1;
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t length = sizeof(address);
    if (bind(fd, (struct sockaddr *)&address, length) != 0 || listen(fd, 1) != 0 ||
        getsockname(fd, (struct sockaddr *)&address, &length) != 0) { close(fd); return -1; }
    *port = ntohs(address.sin_port);
    return fd;
}

- (void)testTLSRoundTripHandlesFragmentedRecords {
    [self runTLSRoundTripWithPeer:@"pairing-host-cert" key:@"pairing-host-key"
                           root:@"pairing-host-cert" expectedSuccess:YES];
}

- (void)testTLSReadCanBeInterruptedBeforeItsTimeoutAndClosedTwice {
    [self runTLSRoundTripWithPeer:@"pairing-host-cert" key:@"pairing-host-key"
                           root:@"pairing-host-cert" expectedSuccess:YES interruptWaitingRead:YES];
}

- (void)testTLSRejectsUntrustedPeer {
    [self runTLSRoundTripWithPeer:@"pairing-host-cert" key:@"pairing-host-key"
                           root:@"unrelated-root" expectedSuccess:NO];
}

- (void)testTLSAcceptsApplePairingCertificatesWithEmptySubject {
    [self runTLSRoundTripWithPeer:@"pairing-empty-device" key:@"pairing-empty-device-key"
                           root:@"pairing-empty-root" expectedSuccess:YES];
}

- (void)testTLSAcceptsPairingCertificateWithoutAuthorityKeyIdentifier {
    [self runTLSRoundTripWithPeer:@"pairing-legacy-device" key:@"pairing-legacy-key"
                           root:@"pairing-legacy-root" expectedSuccess:YES];
}

- (void)testTLSRejectsLegacyPairingCertificateSignedByDifferentEmptyRoot {
    [self runTLSRoundTripWithPeer:@"pairing-legacy-device" key:@"pairing-legacy-key"
                           root:@"pairing-empty-root" expectedSuccess:NO];
}

- (void)testTLSRejectsExpiredLegacyPairingCertificate {
    [self runTLSRoundTripWithPeer:@"pairing-legacy-expired" key:@"pairing-legacy-key"
                           root:@"pairing-legacy-root" expectedSuccess:NO];
}

- (void)testTLSRejectsFutureLegacyPairingCertificate {
    [self runTLSRoundTripWithPeer:@"pairing-legacy-future" key:@"pairing-legacy-key"
                           root:@"pairing-legacy-root" expectedSuccess:NO];
}

- (void)testTLSRejectsLegacyPairingCertificateWithBadSignature {
    [self runTLSRoundTripWithPeer:@"pairing-legacy-bad-signature" key:@"pairing-legacy-key"
                           root:@"pairing-legacy-root" expectedSuccess:NO];
}

- (void)testTLSRejectsLegacyPairingCertificateWithExpiredRoot {
    [self runTLSRoundTripWithPeer:@"pairing-legacy-device" key:@"pairing-legacy-key"
                           root:@"pairing-legacy-expired-root" expectedSuccess:NO];
}

- (void)testTLSRejectsLegacyPairingCertificateWithUnknownCriticalExtension {
    [self runTLSRoundTripWithPeer:@"pairing-legacy-critical" key:@"pairing-legacy-key"
                           root:@"pairing-legacy-root" expectedSuccess:NO];
}

- (void)testTLSRejectsLegacyPairingCALeaf {
    [self runTLSRoundTripWithPeer:@"pairing-legacy-ca-leaf" key:@"pairing-legacy-key"
                           root:@"pairing-legacy-root" expectedSuccess:NO];
}

- (void)testTLSRejectsEmptySubjectPeerOutsidePairingRoot {
    [self runTLSRoundTripWithPeer:@"pairing-empty-device" key:@"pairing-empty-device-key"
                           root:@"unrelated-root" expectedSuccess:NO];
}

- (void)testTLSRejectsExpiredPairingPeer {
    [self runTLSRoundTripWithPeer:@"pairing-empty-expired" key:@"pairing-empty-device-key"
                           root:@"pairing-empty-root" expectedSuccess:NO];
}

- (void)testTLSRejectsPairingPeerWithInvalidSignature {
    [self runTLSRoundTripWithPeer:@"pairing-empty-bad-signature" key:@"pairing-empty-device-key"
                           root:@"pairing-empty-root" expectedSuccess:NO];
}

- (void)runTLSRoundTripWithPeer:(NSString *)peerName key:(NSString *)keyName
                          root:(NSString *)rootName expectedSuccess:(BOOL)expectedSuccess {
    [self runTLSRoundTripWithPeer:peerName key:keyName root:rootName
                 expectedSuccess:expectedSuccess interruptWaitingRead:NO];
}

- (void)runTLSRoundTripWithPeer:(NSString *)peerName key:(NSString *)keyName
                          root:(NSString *)rootName expectedSuccess:(BOOL)expectedSuccess
          interruptWaitingRead:(BOOL)interruptWaitingRead {
    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    NSData *certificateData = [NSData dataWithContentsOfURL:[bundle URLForResource:peerName withExtension:@"der"]];
    NSData *keyData = [NSData dataWithContentsOfURL:[bundle URLForResource:keyName withExtension:@"der"]];
    SecCertificateRef certificate = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)certificateData);
    XCTAssertNotEqual(certificate, NULL);
    if (!certificate) return;
    SecIdentityRef identity = LocSignCreateIdentity(certificate, keyData);
    XCTAssertNotEqual(identity, NULL);
    if (!identity) { CFRelease(certificate); return; }
    uint16_t port = 0;
    int listener = [self listenerWithPort:&port];
    XCTAssertGreaterThanOrEqual(listener, 0);
    if (listener < 0) { CFRelease(identity); CFRelease(certificate); return; }

    XCTestExpectation *finished = [self expectationWithDescription:@"TLS test peer closed"];
    dispatch_semaphore_t peerWaiting = dispatch_semaphore_create(0);
    NSArray *chain = @[(__bridge id)identity];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int fd = accept(listener, NULL, NULL);
        close(listener);
        if (fd < 0) { [finished fulfill]; return; }
        int noSIGPIPE = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, sizeof(noSIGPIPE));
        struct timeval timeout = {.tv_sec = 3};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        LSTestPeer peer = {.fd = fd, .fragmentWrites = YES};
        SSLContextRef tls = SSLCreateContext(NULL, kSSLServerSide, kSSLStreamType);
        SSLSetConnection(tls, &peer);
        SSLSetIOFuncs(tls, LSTestRead, LSTestWrite);
        SSLSetProtocolVersionMin(tls, kTLSProtocol12);
        SSLSetProtocolVersionMax(tls, kTLSProtocol12);
        SSLSetCertificate(tls, (__bridge CFArrayRef)chain);
        OSStatus status;
        do { status = SSLHandshake(tls); } while (status == errSSLWouldBlock);
        if (status == noErr) {
            char request[4] = {0};
            size_t processed = 0;
            status = SSLRead(tls, request, sizeof(request), &processed);
            if (status == noErr && processed == 4 && memcmp(request, "ping", 4) == 0) {
                if (interruptWaitingRead) {
                    dispatch_semaphore_signal(peerWaiting);
                    char unused;
                    recv(fd, &unused, 1, 0); // Keep TLS open without producing a reply.
                } else {
                    SSLWrite(tls, "pong", 4, &processed);
                }
            }
        }
        CFRelease(tls);
        close(fd);
        [finished fulfill];
    });

    NSError *error = nil;
    LSDeviceSocket *client = [[LSDeviceSocket alloc] initWithHost:@"127.0.0.1" port:port timeout:3 error:&error];
    XCTAssertNotNil(client);
    NSData *rootData = [NSData dataWithContentsOfURL:[bundle URLForResource:rootName withExtension:@"der"]];
    SecCertificateRef root = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)rootData);
    XCTAssertNotEqual(root, NULL);
    NSArray *roots = root ? @[(__bridge id)root] : @[];
    BOOL established = [client startTLSWithIdentity:identity certificateChain:@[] trustedRoots:roots error:&error];
    if (expectedSuccess) {
        XCTAssertTrue(established, @"%@", error);
        if (established) {
            XCTAssertTrue([client sendTLSData:[@"ping" dataUsingEncoding:NSUTF8StringEncoding] error:&error]);
            if (interruptWaitingRead) {
                XCTAssertEqual(dispatch_semaphore_wait(peerWaiting,
                    dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)), 0);
                XCTestExpectation *interrupted = [self expectationWithDescription:@"socket shutdown issued"];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10),
                    dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                        [client interrupt];
                        [interrupted fulfill];
                    });
                NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
                XCTAssertNil([client readTLSLength:4 error:&error]);
                XCTAssertNotNil(error);
                XCTAssertLessThan(NSProcessInfo.processInfo.systemUptime - started, 2);
                [self waitForExpectations:@[interrupted] timeout:2];
            } else {
                XCTAssertEqualObjects([client readTLSLength:4 error:&error], [@"pong" dataUsingEncoding:NSUTF8StringEncoding]);
            }
        }
    } else {
        XCTAssertFalse(established);
        XCTAssertNotNil(error);
        NSError *verificationError = error.userInfo[NSUnderlyingErrorKey];
        XCTAssertEqualObjects(verificationError.domain, @"LocSign.PairingTrust");
        if ([peerName isEqualToString:@"pairing-empty-expired"]) {
            XCTAssertEqual(verificationError.code, 10); // X509_V_ERR_CERT_HAS_EXPIRED
        } else if ([peerName isEqualToString:@"pairing-empty-bad-signature"]) {
            XCTAssertEqual(verificationError.code, 7); // X509_V_ERR_CERT_SIGNATURE_FAILURE
        } else if ([peerName isEqualToString:@"pairing-legacy-expired"] ||
                   [rootName isEqualToString:@"pairing-legacy-expired-root"]) {
            XCTAssertEqual(verificationError.code, 10);
        } else if ([peerName isEqualToString:@"pairing-legacy-future"]) {
            XCTAssertEqual(verificationError.code, 9);
        } else if ([peerName isEqualToString:@"pairing-legacy-bad-signature"] ||
                   ([peerName isEqualToString:@"pairing-legacy-device"] && [rootName isEqualToString:@"pairing-empty-root"])) {
            XCTAssertEqual(verificationError.code, 7);
        } else if ([peerName isEqualToString:@"pairing-legacy-critical"]) {
            XCTAssertEqual(verificationError.code, 34);
        } else if ([peerName isEqualToString:@"pairing-legacy-ca-leaf"]) {
            XCTAssertEqual(verificationError.code, 37);
        }
    }
    [client close];
    if (interruptWaitingRead) [client close];
    [self waitForExpectations:@[finished] timeout:8];
    CFRelease(identity);
    CFRelease(certificate);
    if (root) CFRelease(root);
}

- (void)testRawReadTimesOutWithoutResponse {
    uint16_t port = 0;
    int listener = [self listenerWithPort:&port];
    XCTAssertGreaterThanOrEqual(listener, 0);
    if (listener < 0) return;
    NSError *error = nil;
    LSDeviceSocket *client = [[LSDeviceSocket alloc] initWithHost:@"127.0.0.1" port:port timeout:0.2 error:&error];
    XCTAssertNotNil(client);
    int peer = accept(listener, NULL, NULL);
    NSDate *start = NSDate.date;
    XCTAssertNil([client readRawLength:4 error:&error]);
    XCTAssertNotNil(error);
    XCTAssertLessThan(-start.timeIntervalSinceNow, 2);
    [client close];
    close(peer);
    close(listener);
}
@end
#pragma clang diagnostic pop
