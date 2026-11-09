//
//  FluxoEngineHTTP.m
//  Fluxo
//
//  HTTP and HTTPS connections of the remux engine through URLSession, see FluxoEngineHTTP.h.
//
//  Every connection of an engine session is a data task of the session's client (FluxoHTTPClient), an ephemeral
//  URLSession of its own (cookies and connections are kept in memory only, for that engine session only; nothing is
//  cached on disk), whose delegate queue is serial: the delegate appends the data to
//  the connection's buffer and suspends the task when the buffer is full; the engine thread reads the buffer and asks
//  the queue to resume the task once it has room again. The calls that change the task's state (suspend, resume) are
//  all made on that queue, in order.
//

#import <Foundation/Foundation.h>
#import <Security/Security.h>

#include "FluxoEngineHTTP.h"
#include "FluxoRemuxEngine.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include <libavformat/version.h>
#include <libavutil/mem.h>
#pragma clang diagnostic pop

// The User-Agent of FFmpeg's http protocol (DEFAULT_USER_AGENT in http.c): servers that filter clients by it see the
// engine as they did before.
#define FLUXO_HTTP_DEFAULT_USER_AGENT "Lavf/" AV_STRINGIFY(LIBAVFORMAT_VERSION)
// The engine thread checks the interrupt callback this often while it waits (FFmpeg's network protocols: 100 ms).
static const NSTimeInterval FluxoHTTPPollInterval = 0.1;
// fluxo_http_close waits at most this long for the cancelled task to end.
static const NSTimeInterval FluxoHTTPCloseWait = 1.0;
// The URL loading system's own idle timeout (timeoutInterval, timeoutIntervalForRequest), which is not the engine's
// read timeout: that timer also runs while the task is suspended by the flow control, so it would cut a connection
// the engine merely leaves unread (an on-demand movie read 60 s ahead waits until it is 30 s ahead; a paused movie),
// which FFmpeg's socket never did. The engine's timeout (FluxoHTTPRequest.timeout_us, FFmpeg's rw_timeout) is
// enforced by the engine thread while it waits for data (-waitUntil:deadline:), and only then; this one only ends a
// task nobody closes.
static const NSTimeInterval FluxoHTTPSystemIdleTimeout = 7 * 24 * 3600;

@class FluxoHTTPTask;

static int FluxoHTTPErrorFromNSError(NSError *error);

// The user and password of an address (percent-decoded), nil without a user.
static NSURLCredential *FluxoHTTPCredentialFromURL(NSURL *url) {
    if (url.user.length == 0) {
        return nil;
    }
    return [NSURLCredential credentialWithUser:url.user.stringByRemovingPercentEncoding ?: url.user
                                      password:url.password.stringByRemovingPercentEncoding ?: (url.password ?: @"")
                                   persistence:NSURLCredentialPersistenceNone];
}

static NSInteger FluxoHTTPPort(NSString *scheme, NSNumber *port) {
    return port != nil ? port.integerValue : ([scheme isEqualToString:@"https"] ? 443 : 80);
}

// The protection space is the server of the address: the same scheme, host and port.
static BOOL FluxoHTTPSameOrigin(NSURL *url, NSURLProtectionSpace *space) {
    NSString *scheme = url.scheme.lowercaseString;
    if (scheme == nil || url.host == nil || space.protocol == nil || space.host == nil) {
        return NO;
    }
    // (A protection space without a port is the scheme's default one.)
    NSInteger spacePort = space.port > 0 ? space.port : FluxoHTTPPort(space.protocol.lowercaseString, nil);
    return [space.protocol.lowercaseString isEqualToString:scheme] && [space.host caseInsensitiveCompare:url.host] == NSOrderedSame &&
           spacePort == FluxoHTTPPort(scheme, url.port);
}

// MARK: - Session

@interface FluxoHTTPSessionDelegate : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, readonly) NSOperationQueue *queue;
- (void)registerTask:(FluxoHTTPTask *)task identifier:(NSUInteger)identifier;
@end

// The client of one engine session (FluxoHTTPClient).
@interface FluxoHTTPClientObject : NSObject
@property (nonatomic, readonly) NSURLSession *session;
@property (nonatomic, readonly) FluxoHTTPSessionDelegate *delegate;
@end

// MARK: - Connection

// One request and its response. The headers, credential and redirection count are set before the task starts and
// then used on the session's queue only; everything from the response on is guarded by the condition.
@interface FluxoHTTPTask : NSObject {
@public
    NSCondition *_condition;
    NSURLSessionDataTask *_task;
    __weak FluxoHTTPSessionDelegate *_delegate;
    // The headers every request of this connection carries, redirections included.
    NSDictionary<NSString *, NSString *> *_headers;
    // The user and password of the address, and the address they belong to (its scheme, host and port): they answer
    // that server's challenges only.
    NSURLCredential *_credential;
    NSURL *_credentialURL;
    int _redirects;

    NSHTTPURLResponse *_response;
    BOOL _finished;
    NSError *_error;
    // Data received and not read yet, the bytes of its first chunk already read, and their total.
    NSMutableArray<NSData *> *_chunks;
    NSUInteger _chunkOffset;
    NSUInteger _buffered;
    // The task is suspended because the buffer is full; a resume is queued.
    BOOL _flowSuspended;
    BOOL _resumeQueued;

    // Read on the engine thread after the response (fluxo_http_* getters).
    int _status;
    int64_t _start;
    int64_t _size;
    int _seekable;
    char *_mimeType;
    char *_location;
    int64_t _timeoutUs;
    AVIOInterruptCB _interrupt;
}
@end

@implementation FluxoHTTPTask

- (instancetype)init {
    self = [super init];
    if (self) {
        _condition = [[NSCondition alloc] init];
        _chunks = [NSMutableArray array];
        _start = 0;
        _size = -1;
    }
    return self;
}

- (void)dealloc {
    free(_mimeType);
    free(_location);
}

// MARK: Delegate side (the session's queue)

- (void)didReceiveResponse:(NSURLResponse *)response {
    [_condition lock];
    _response = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    [_condition broadcast];
    [_condition unlock];
}

- (void)didReceiveData:(NSData *)data {
    [_condition lock];
    [_chunks addObject:data];
    _buffered += data.length;
    BOOL suspend = !_flowSuspended && _buffered >= FLUXO_HTTP_HIGH_WATER && !_finished;
    if (suspend) {
        _flowSuspended = YES;
    }
    [_condition broadcast];
    [_condition unlock];
    if (suspend) {
        [_task suspend];
    }
}

- (void)didCompleteWithError:(NSError *)error {
    [_condition lock];
    _finished = YES;
    _error = error;
    [_condition broadcast];
    [_condition unlock];
}

// Queued by the reader once the buffer has room: resumes a task the delegate suspended (on the queue, so after it).
- (void)resumeFlow {
    [_condition lock];
    BOOL resume = _flowSuspended && _buffered <= FLUXO_HTTP_LOW_WATER;
    if (resume) {
        _flowSuspended = NO;
    }
    _resumeQueued = NO;
    [_condition unlock];
    if (resume) {
        [_task resume];
    }
}

- (NSURLRequest *)redirectRequest:(NSURLRequest *)request {
    if (++_redirects > FLUXO_HTTP_MAX_REDIRECTS) {
        // The redirection itself becomes the response, which fluxo_http_open refuses (EIO, as FFmpeg's).
        return nil;
    }
    // A user and password in the new address answer its server from now on, as in FFmpeg's http protocol, which takes
    // the credentials of the Location after a redirection. (Without them, those of the first address still answer its
    // own server only, see -credentialForChallenge:.)
    NSURLCredential *credential = FluxoHTTPCredentialFromURL(request.URL);
    if (credential != nil) {
        _credential = credential;
        _credentialURL = request.URL;
    }
    NSMutableURLRequest *redirected = [request mutableCopy];
    for (NSString *name in _headers) {
        [redirected setValue:_headers[name] forHTTPHeaderField:name];
    }
    return redirected;
}

// The user and password of the address answer a Basic or Digest challenge of the server they were given for only (the
// same scheme, host and port: not another server a redirection leads to, nor the same one over http:// after
// https://), once, as FFmpeg's http protocol does.
- (NSURLCredential *)credentialForChallenge:(NSURLAuthenticationChallenge *)challenge {
    NSURLProtectionSpace *space = challenge.protectionSpace;
    NSString *method = space.authenticationMethod;
    BOOL password = [method isEqualToString:NSURLAuthenticationMethodHTTPBasic] || [method isEqualToString:NSURLAuthenticationMethodHTTPDigest];
    if (!password || space.isProxy || _credential == nil || challenge.previousFailureCount != 0) {
        return nil;
    }
    return FluxoHTTPSameOrigin(_credentialURL, space) ? _credential : nil;
}

// MARK: Engine side

static int FluxoHTTPInterrupted(const AVIOInterruptCB *interrupt) {
    return interrupt->callback != NULL && interrupt->callback(interrupt->opaque);
}

// Waits on the condition (locked) until `done` holds, the deadline passes or the interrupt callback asks to stop.
// Returns 0, AVERROR(ETIMEDOUT) or AVERROR_EXIT; the condition stays locked.
- (int)waitUntil:(BOOL (^)(void))done deadline:(NSDate *)deadline {
    while (!done()) {
        if (FluxoHTTPInterrupted(&_interrupt)) {
            return AVERROR_EXIT;
        }
        NSDate *now = [NSDate date];
        if ([now compare:deadline] != NSOrderedAscending) {
            return AVERROR(ETIMEDOUT);
        }
        NSDate *step = [now dateByAddingTimeInterval:FluxoHTTPPollInterval];
        [_condition waitUntilDate:[step earlierDate:deadline]];
    }
    return 0;
}

- (NSDate *)deadline {
    return [NSDate dateWithTimeIntervalSinceNow:(NSTimeInterval)_timeoutUs / 1e6];
}

- (int)read:(uint8_t *)buffer size:(int)size {
    if (size <= 0) {
        return 0;
    }
    [_condition lock];
    int ret = [self waitUntil:^BOOL { return self->_buffered > 0 || self->_finished; } deadline:[self deadline]];
    if (ret < 0) {
        [_condition unlock];
        return ret;
    }
    if (_buffered == 0) {
        // Ended, and everything was read.
        ret = _error != nil ? FluxoHTTPErrorFromNSError(_error) : AVERROR_EOF;
        [_condition unlock];
        // An address or a response the system refused mid-stream is a failed read, not a reason to change protocol.
        return ret == FLUXO_HTTP_ERROR_INCOMPATIBLE ? AVERROR(EIO) : ret;
    }
    NSUInteger copied = 0;
    while (copied < (NSUInteger)size && _chunks.count > 0) {
        NSData *chunk = _chunks.firstObject;
        NSUInteger count = MIN(chunk.length - _chunkOffset, (NSUInteger)size - copied);
        [chunk getBytes:buffer + copied range:NSMakeRange(_chunkOffset, count)];
        copied += count;
        _chunkOffset += count;
        if (_chunkOffset == chunk.length) {
            [_chunks removeObjectAtIndex:0];
            _chunkOffset = 0;
        }
    }
    _buffered -= copied;
    BOOL queueResume = _flowSuspended && !_resumeQueued && _buffered <= FLUXO_HTTP_LOW_WATER;
    if (queueResume) {
        _resumeQueued = YES;
    }
    [_condition unlock];
    if (queueResume) {
        FluxoHTTPSessionDelegate *delegate = _delegate;
        [delegate.queue addOperationWithBlock:^{
            [self resumeFlow];
        }];
    }
    return (int)copied;
}

// A response without a type or a length may be one the URL loading system did not understand: it takes a status line
// that is not HTTP's (SHOUTcast's "ICY 200 OK"), or an HTTP/1.x one it could not parse, for an HTTP/0.9 response without
// headers, and gives the status line and the headers as the body. FFmpeg's http protocol reads those. Waits for the
// first bytes (at most the timeout): FLUXO_HTTP_ERROR_INCOMPATIBLE when they are such a status line, AVERROR(ETIMEDOUT)
// when nothing came (the open fails after one timeout, as FFmpeg's waiting for the response), 0 otherwise.
- (int)checkStatusLineInBody {
    static const char *const prefixes[] = { "ICY ", "HTTP/" };
    [_condition lock];
    int ret = [self waitUntil:^BOOL { return self->_buffered >= 5 || self->_finished; } deadline:[self deadline]];
    char first[6] = { 0 };
    NSUInteger length = 0;
    for (NSData *chunk in _chunks) {
        NSUInteger count = MIN(chunk.length - (length == 0 ? _chunkOffset : 0), (NSUInteger)5 - length);
        [chunk getBytes:first + length range:NSMakeRange(length == 0 ? _chunkOffset : 0, count)];
        length += count;
        if (length == 5) {
            break;
        }
    }
    [_condition unlock];
    if (ret == AVERROR_EXIT || (ret == AVERROR(ETIMEDOUT) && length == 0)) {
        return ret;
    }
    for (size_t i = 0; i < sizeof(prefixes) / sizeof(prefixes[0]); i++) {
        if (length >= strlen(prefixes[i]) && strncmp(first, prefixes[i], strlen(prefixes[i])) == 0) {
            return FLUXO_HTTP_ERROR_INCOMPATIBLE;
        }
    }
    // (Some bytes and then a timeout: the body started, the reader reports what follows.)
    return 0;
}

- (void)closeWaiting:(NSTimeInterval)wait {
    [_condition lock];
    BOOL finished = _finished;
    [_condition unlock];
    if (finished) {
        return;
    }
    // (A suspended task can be cancelled too.)
    [_task cancel];
    [_condition lock];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:wait];
    while (!_finished && [_condition waitUntilDate:deadline]) {
    }
    [_condition unlock];
}

// MARK: Errors

// The POSIX error under a URL loading error, when CFNetwork gives one (its stream error, in the POSIX domain).
static long FluxoHTTPPOSIXError(NSError *error) {
    for (NSError *current = error; current != nil; current = current.userInfo[NSUnderlyingErrorKey]) {
        if ([current.domain isEqualToString:NSPOSIXErrorDomain]) {
            return current.code;
        }
        NSNumber *domain = current.userInfo[@"_kCFStreamErrorDomainKey"];
        NSNumber *code = current.userInfo[@"_kCFStreamErrorCodeKey"];
        if ([domain isKindOfClass:[NSNumber class]] && [code isKindOfClass:[NSNumber class]] && domain.longValue == kCFStreamErrorDomainPOSIX &&
            code.longValue > 0) {
            return code.longValue;
        }
    }
    return 0;
}

static int FluxoHTTPErrorFromNSError(NSError *error) {
#ifdef FLUXO_ENGINE_TESTING
    if (getenv("FLUXO_HTTP_TRACE") != NULL) {
        NSLog(@"[http] %@", error);
    }
#endif
    if ([error.domain isEqualToString:NSURLErrorDomain]) {
        return fluxo_http_error_from_url_error(error.code, FluxoHTTPPOSIXError(error));
    }
    if ([error.domain isEqualToString:NSPOSIXErrorDomain] && error.code > 0) {
        return AVERROR((int)error.code);
    }
    return AVERROR(EIO);
}

@end

int fluxo_http_error_from_url_error(long code, long posix_error) {
    int posix = posix_error > 0 && posix_error < 256 ? (int)posix_error : 0;
    switch (code) {
    case NSURLErrorCancelled:
        return AVERROR_EXIT;
    case NSURLErrorTimedOut:
        return AVERROR(ETIMEDOUT);
    case NSURLErrorCannotFindHost:
    case NSURLErrorDNSLookupFailed:
        // FFmpeg's failed name lookup (tcp.c) has no code of its own.
        return AVERROR(EIO);
    case NSURLErrorCannotConnectToHost:
        return AVERROR(posix != 0 ? posix : ECONNREFUSED);
    case NSURLErrorNetworkConnectionLost:
        // A reset connection (an HTTP/2 stream the server reset gives ENOTCONN), or one the server closed before the end
        // of the response (FFmpeg's "Stream ends prematurely", EIO).
        return AVERROR(posix == ENOTCONN ? ECONNRESET : posix != 0 ? posix : EIO);
    case NSURLErrorNotConnectedToInternet:
    case NSURLErrorInternationalRoamingOff:
    case NSURLErrorCallIsActive:
    case NSURLErrorDataNotAllowed:
        return AVERROR(ENETUNREACH);
    case NSURLErrorServerCertificateHasBadDate:
    case NSURLErrorServerCertificateUntrusted:
    case NSURLErrorServerCertificateHasUnknownRoot:
    case NSURLErrorServerCertificateNotYetValid:
        return FLUXO_REMUX_ERROR_TLS_CERTIFICATE;
    case NSURLErrorSecureConnectionFailed:
    case NSURLErrorClientCertificateRejected:
    case NSURLErrorClientCertificateRequired:
        return FLUXO_REMUX_ERROR_TLS_HANDSHAKE;
    case NSURLErrorUserAuthenticationRequired:
    case NSURLErrorUserCancelledAuthentication:
        return AVERROR_HTTP_UNAUTHORIZED;
    case NSURLErrorZeroByteResource:
        return AVERROR_EOF;
    case NSURLErrorBadURL:
    case NSURLErrorUnsupportedURL:
    case NSURLErrorBadServerResponse:
    case NSURLErrorCannotParseResponse:
    case NSURLErrorCannotDecodeRawData:
    case NSURLErrorCannotDecodeContentData:
        return FLUXO_HTTP_ERROR_INCOMPATIBLE;
    default:
        return AVERROR(posix != 0 ? posix : EIO);
    }
}

// As FFmpeg's ff_http_averror.
int fluxo_http_error_from_status(int status) {
    switch (status) {
    case 400:
        return AVERROR_HTTP_BAD_REQUEST;
    case 401:
        return AVERROR_HTTP_UNAUTHORIZED;
    case 403:
        return AVERROR_HTTP_FORBIDDEN;
    case 404:
        return AVERROR_HTTP_NOT_FOUND;
    case 429:
        return AVERROR_HTTP_TOO_MANY_REQUESTS;
    default:
        break;
    }
    if (status >= 400 && status <= 499) {
        return AVERROR_HTTP_OTHER_4XX;
    }
    if (status >= 500) {
        return AVERROR_HTTP_SERVER_ERROR;
    }
    return AVERROR(EIO);
}

// MARK: - Session delegate

#ifdef FLUXO_ENGINE_TESTING
// Tools/EngineSmokeTest only, never the app: the certificate authority of the local TLS test servers
// (FLUXO_TEST_CA_FILE, PEM), the only anchor their certificates are checked against (name, dates and chain still
// are). The app trusts what the system trusts; in the iOS Simulator the test authority is added to the simulator's
// keychain instead (xcrun simctl keychain <udid> add-root-cert).
static NSArray *FluxoHTTPTestAnchors(void) {
    static NSArray *anchors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *path = getenv("FLUXO_TEST_CA_FILE");
        NSString *pem = path != NULL ? [NSString stringWithContentsOfFile:@(path) encoding:NSUTF8StringEncoding error:NULL] : nil;
        if (pem == nil) {
            return;
        }
        NSRange begin = [pem rangeOfString:@"-----BEGIN CERTIFICATE-----"];
        NSRange end = [pem rangeOfString:@"-----END CERTIFICATE-----"];
        if (begin.location == NSNotFound || end.location == NSNotFound || end.location < NSMaxRange(begin)) {
            return;
        }
        NSString *body = [pem substringWithRange:NSMakeRange(NSMaxRange(begin), end.location - NSMaxRange(begin))];
        NSData *der = [[NSData alloc] initWithBase64EncodedString:body options:NSDataBase64DecodingIgnoreUnknownCharacters];
        SecCertificateRef certificate = der != nil ? SecCertificateCreateWithData(NULL, (__bridge CFDataRef)der) : NULL;
        if (certificate != NULL) {
            anchors = @[ (__bridge_transfer id)certificate ];
        }
    });
    return anchors;
}
#endif

@implementation FluxoHTTPSessionDelegate {
    NSLock *_lock;
    NSMutableDictionary<NSNumber *, FluxoHTTPTask *> *_tasks;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _tasks = [NSMutableDictionary dictionary];
        _queue = [[NSOperationQueue alloc] init];
        _queue.maxConcurrentOperationCount = 1;
        _queue.qualityOfService = NSQualityOfServiceUserInitiated;
        _queue.name = @"dev.watermelon.Fluxo.engine-http";
    }
    return self;
}

- (void)registerTask:(FluxoHTTPTask *)task identifier:(NSUInteger)identifier {
    [_lock lock];
    _tasks[@(identifier)] = task;
    [_lock unlock];
}

- (FluxoHTTPTask *)taskFor:(NSURLSessionTask *)task remove:(BOOL)remove {
    [_lock lock];
    NSNumber *key = @(task.taskIdentifier);
    FluxoHTTPTask *result = _tasks[key];
    if (remove) {
        [_tasks removeObjectForKey:key];
    }
    [_lock unlock];
    return result;
}

- (void)URLSession:(NSURLSession *)session
              dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    [[self taskFor:dataTask remove:NO] didReceiveResponse:response];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    [[self taskFor:dataTask remove:NO] didReceiveData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    [[self taskFor:task remove:YES] didCompleteWithError:error];
}

- (void)URLSession:(NSURLSession *)session
                          task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                    newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *))completionHandler {
    FluxoHTTPTask *connection = [self taskFor:task remove:NO];
    completionHandler(connection != nil ? [connection redirectRequest:request] : request);
}

- (void)URLSession:(NSURLSession *)session
                   task:(NSURLSessionTask *)task
    didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
      completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
#ifdef FLUXO_ENGINE_TESTING
    NSString *method = challenge.protectionSpace.authenticationMethod;
    NSArray *anchors = [method isEqualToString:NSURLAuthenticationMethodServerTrust] ? FluxoHTTPTestAnchors() : nil;
    if (anchors != nil) {
        SecTrustRef trust = challenge.protectionSpace.serverTrust;
        SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)anchors);
        SecTrustSetAnchorCertificatesOnly(trust, true);
        if (SecTrustEvaluateWithError(trust, NULL)) {
            completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
        } else {
            // Refused as the app refuses it: the system's evaluation, with its error.
            completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        }
        return;
    }
#endif
    // The user and password of the address answer its server's challenge (-credentialForChallenge:). The server's
    // certificate is checked by the system (default handling), as for every other connection of the app.
    NSURLCredential *credential = [[self taskFor:task remove:NO] credentialForChallenge:challenge];
    if (credential != nil) {
        completionHandler(NSURLSessionAuthChallengeUseCredential, credential);
        return;
    }
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

@end

@implementation FluxoHTTPClientObject

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        // Media are read once: no cache, in memory or on disk.
        configuration.URLCache = nil;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        // Cookies a server sets (a redirection to a tokenized address, a panel's session) go back to it with the next
        // requests of this engine session: the cookie storage of an ephemeral configuration is its own, in memory, and
        // goes with the client (FFmpeg kept them within a connection).
        configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
        configuration.HTTPMaximumConnectionsPerHost = FLUXO_HTTP_MAX_CONNECTIONS_PER_HOST;
        configuration.networkServiceType = NSURLNetworkServiceTypeAVStreaming;
        // (The engine enforces its own timeout: FluxoHTTPSystemIdleTimeout.)
        configuration.timeoutIntervalForRequest = FluxoHTTPSystemIdleTimeout;
        _delegate = [[FluxoHTTPSessionDelegate alloc] init];
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:_delegate delegateQueue:_delegate.queue];
    }
    return self;
}

@end

// MARK: - C interface

static char *FluxoHTTPCopyString(NSString *string) {
    return string != nil ? strdup(string.UTF8String) : NULL;
}

// "bytes 100-199/1000": the start and the total (-1 for "*").
static BOOL FluxoHTTPParseContentRange(NSString *value, int64_t *start, int64_t *total) {
    if (![value hasPrefix:@"bytes "]) {
        return NO;
    }
    const char *text = value.UTF8String + 6;
    char *end = NULL;
    long long first = strtoll(text, &end, 10);
    if (end == text || first < 0) {
        return NO;
    }
    const char *slash = strchr(text, '/');
    long long length = slash != NULL && slash[1] != '*' ? strtoll(slash + 1, NULL, 10) : -1;
    *start = first;
    *total = length > 0 ? length : -1;
    return YES;
}

static int FluxoHTTPOpen(const FluxoHTTPRequest *request, FluxoHTTPConnection **result) {
    NSString *address = request->url != NULL ? [NSString stringWithUTF8String:request->url] : nil;
    NSURL *url = address != nil ? [NSURL URLWithString:address] : nil;
    NSString *scheme = url.scheme.lowercaseString;
    if (url == nil || url.host.length == 0 || !([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
        return FLUXO_HTTP_ERROR_INCOMPATIBLE;
    }

    FluxoHTTPClientObject *client = (__bridge FluxoHTTPClientObject *)request->client;
    if (client == nil) {
        return AVERROR(EINVAL);
    }
    FluxoHTTPSessionDelegate *delegate = client.delegate;
    NSURLSession *session = client.session;
    FluxoHTTPTask *connection = [[FluxoHTTPTask alloc] init];
    connection->_timeoutUs = request->timeout_us > 0 ? request->timeout_us : 15 * 1000000LL;
    connection->_interrupt = request->interrupt;
    connection->_delegate = delegate;

    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
    headers[@"User-Agent"] = request->user_agent != NULL && request->user_agent[0] != '\0' ? @(request->user_agent) : @FLUXO_HTTP_DEFAULT_USER_AGENT;
    headers[@"Accept"] = @"*/*";
    // The body as it is: byte positions must be the resource's (FFmpeg's http protocol asks for no encoding either).
    headers[@"Accept-Encoding"] = @"identity";
    int64_t offset = request->offset > 0 ? request->offset : 0;
    headers[@"Range"] = request->end_offset > offset ? [NSString stringWithFormat:@"bytes=%lld-%lld", (long long)offset, (long long)request->end_offset - 1]
                                                     : [NSString stringWithFormat:@"bytes=%lld-", (long long)offset];
    connection->_headers = headers;
    connection->_credential = FluxoHTTPCredentialFromURL(url);
    connection->_credentialURL = url;

    // The timeout (FFmpeg's rw_timeout) limits the wait for the response below and every wait of the reader for data,
    // and nothing else: a connection the engine does not read stays open, as FFmpeg's socket did. Not the URL loading
    // system's idle timer, which also runs while the flow control suspends the task (FluxoHTTPSystemIdleTimeout).
    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:url
                                                              cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                          timeoutInterval:FluxoHTTPSystemIdleTimeout];
    for (NSString *name in headers) {
        [urlRequest setValue:headers[name] forHTTPHeaderField:name];
    }
    NSURLSessionDataTask *task = [session dataTaskWithRequest:urlRequest];
    connection->_task = task;
    [delegate registerTask:connection identifier:task.taskIdentifier];
    [task resume];

    [connection->_condition lock];
    int ret = [connection waitUntil:^BOOL { return connection->_response != nil || connection->_finished; } deadline:[connection deadline]];
    NSHTTPURLResponse *response = connection->_response;
    NSError *error = connection->_error;
    [connection->_condition unlock];
    if (ret == 0 && response == nil) {
        ret = error != nil ? FluxoHTTPErrorFromNSError(error) : AVERROR(EIO);
    }
    if (ret == 0) {
        connection->_status = (int)response.statusCode;
        if (response.statusCode < 200 || response.statusCode > 299) {
            ret = fluxo_http_error_from_status(connection->_status);
        }
    }
    if (ret == 0 && [response valueForHTTPHeaderField:@"Content-Type"] == nil && response.expectedContentLength < 0) {
        ret = [connection checkStatusLineInBody];
    }
    if (ret < 0) {
        [connection closeWaiting:FluxoHTTPCloseWait];
        return ret;
    }

    int64_t start = 0;
    int64_t total = -1;
    NSString *contentRange = [response valueForHTTPHeaderField:@"Content-Range"];
    BOOL partial = response.statusCode == 206;
    if (partial && FluxoHTTPParseContentRange(contentRange, &start, &total)) {
        connection->_start = start;
        connection->_size = total;
    } else if (partial) {
        // A 206 without a (readable) Content-Range is the range asked for, as FFmpeg's http protocol takes it (it keeps
        // the requested offset). Asked to the end, the body's length gives the resource's.
        connection->_start = offset;
        connection->_size = request->end_offset <= offset && response.expectedContentLength >= 0 ? offset + response.expectedContentLength : -1;
    } else {
        connection->_start = 0;
        connection->_size = response.expectedContentLength >= 0 ? response.expectedContentLength : -1;
    }
    NSString *acceptRanges = [response valueForHTTPHeaderField:@"Accept-Ranges"];
    connection->_seekable = partial || [acceptRanges hasPrefix:@"bytes"];
    connection->_mimeType = FluxoHTTPCopyString([response valueForHTTPHeaderField:@"Content-Type"]);
    connection->_location = FluxoHTTPCopyString((response.URL ?: url).absoluteString);
    *result = (FluxoHTTPConnection *)CFBridgingRetain(connection);
    return 0;
}

int fluxo_http_client_create(FluxoHTTPClient **client) {
    *client = NULL;
    @autoreleasepool {
        FluxoHTTPClientObject *object = [[FluxoHTTPClientObject alloc] init];
        if (object.session == nil) {
            return AVERROR(ENOMEM);
        }
        *client = (FluxoHTTPClient *)CFBridgingRetain(object);
        return 0;
    }
}

void fluxo_http_client_free(FluxoHTTPClient **client) {
    if (client == NULL || *client == NULL) {
        return;
    }
    @autoreleasepool {
        FluxoHTTPClientObject *object = CFBridgingRelease(*client);
        *client = NULL;
        // The session keeps its delegate until it is invalidated; its cookies go with it.
        [object.session invalidateAndCancel];
    }
}

char *fluxo_http_client_cookies(FluxoHTTPClient *client, const char *url) {
    if (client == NULL || url == NULL) {
        return NULL;
    }
    @autoreleasepool {
        NSString *address = [NSString stringWithUTF8String:url];
        NSURL *target = address != nil ? [NSURL URLWithString:address] : nil;
        NSArray<NSHTTPCookie *> *cookies = target != nil ? [((__bridge FluxoHTTPClientObject *)client).session.configuration.HTTPCookieStorage cookiesForURL:target] : nil;
        if (cookies.count == 0) {
            return NULL;
        }
        NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:cookies.count];
        for (NSHTTPCookie *cookie in cookies) {
            // FFmpeg compares the end of the request's host with the domain: without the leading dot, a domain cookie
            // ("Domain=example.com") matches example.com itself as well as its subdomains.
            NSString *domain = [cookie.domain hasPrefix:@"."] ? [cookie.domain substringFromIndex:1] : cookie.domain;
            [lines addObject:[NSString stringWithFormat:@"%@=%@; domain=%@; path=%@", cookie.name, cookie.value, domain, cookie.path.length > 0 ? cookie.path : @"/"]];
        }
        return av_strdup([lines componentsJoinedByString:@"\n"].UTF8String);
    }
}

int fluxo_http_open(const FluxoHTTPRequest *request, FluxoHTTPConnection **connection) {
    *connection = NULL;
    @autoreleasepool {
        return FluxoHTTPOpen(request, connection);
    }
}

int fluxo_http_read(FluxoHTTPConnection *connection, uint8_t *buffer, int size) {
    @autoreleasepool {
        return [(__bridge FluxoHTTPTask *)connection read:buffer size:size];
    }
}

int fluxo_http_status(const FluxoHTTPConnection *connection) {
    return ((__bridge FluxoHTTPTask *)connection)->_status;
}

int64_t fluxo_http_start(const FluxoHTTPConnection *connection) {
    return ((__bridge FluxoHTTPTask *)connection)->_start;
}

int64_t fluxo_http_size(const FluxoHTTPConnection *connection) {
    return ((__bridge FluxoHTTPTask *)connection)->_size;
}

int fluxo_http_seekable(const FluxoHTTPConnection *connection) {
    return ((__bridge FluxoHTTPTask *)connection)->_seekable;
}

const char *fluxo_http_mime_type(const FluxoHTTPConnection *connection) {
    return ((__bridge FluxoHTTPTask *)connection)->_mimeType;
}

const char *fluxo_http_location(const FluxoHTTPConnection *connection) {
    return ((__bridge FluxoHTTPTask *)connection)->_location;
}

void fluxo_http_close(FluxoHTTPConnection **connection) {
    if (connection == NULL || *connection == NULL) {
        return;
    }
    @autoreleasepool {
        FluxoHTTPTask *task = CFBridgingRelease(*connection);
        *connection = NULL;
        [task closeWaiting:FluxoHTTPCloseWait];
    }
}
