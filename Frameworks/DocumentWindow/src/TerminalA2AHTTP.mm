#import "TerminalA2AHTTP.h"
#import <EditorContextProtocol.h>
#include <netinet/in.h>

namespace {
constexpr NSUInteger headerLimit = 8192;
constexpr NSUInteger bodyLimit = 512 * 1024;
static_assert(editor_context::a2a_text_limit * 6 < bodyLimit);

bool receive(int fd, NSMutableData* buffer, NSUInteger limit, double deadline) {
    char bytes[4096];
    while(buffer.length < limit && editor_context::wait_for(fd, POLLIN, deadline)) {
        ssize_t count = recv(fd, bytes, MIN(sizeof(bytes), limit - buffer.length), MSG_DONTWAIT);
        if(count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if(count <= 0) return false;
        [buffer appendBytes:bytes length:count];
        return true;
    }
    return false;
}

bool sendData(int fd, NSData* data, double deadline) {
    auto bytes = static_cast<char const*>(data.bytes);
    NSUInteger sent = 0;
    while(sent < data.length && editor_context::wait_for(fd, POLLOUT, deadline)) {
        ssize_t count = send(fd, bytes + sent, data.length - sent, MSG_DONTWAIT);
        if(count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if(count <= 0) return false;
        sent += count;
    }
    return sent == data.length;
}

NSDictionary* requestFromSocket(int fd, NSString* host, TerminalA2ARequest request, double deadline) {
    static NSData* separator = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
    NSMutableData* buffer = [NSMutableData data];
    NSRange boundary = { NSNotFound, 0 };
    while(receive(fd, buffer, headerLimit, deadline)) {
        boundary = [buffer rangeOfData:separator options:0 range:NSMakeRange(0, buffer.length)];
        if(boundary.location != NSNotFound) break;
    }
    NSDictionary* invalid = TerminalA2AProblem(400, @"invalid_request", @"Malformed HTTP request.");
    if(boundary.location == NSNotFound) return invalid;
    NSString* head = [[NSString alloc] initWithData:[buffer subdataWithRange:NSMakeRange(0, boundary.location)] encoding:NSASCIIStringEncoding];
    NSArray* lines = [head componentsSeparatedByString:@"\r\n"];
    NSArray* start = [lines.firstObject componentsSeparatedByString:@" "];
    if(start.count != 3 || ![start[1] hasPrefix:@"/"] ||
       ![@[@"HTTP/1.0", @"HTTP/1.1"] containsObject:start[2]]) return invalid;
    NSMutableDictionary* headers = [NSMutableDictionary dictionary];
    for(NSUInteger index = 1; index < lines.count; ++index) {
        NSString* line = lines[index];
        NSRange colon = [line rangeOfString:@":"];
        if(colon.location == NSNotFound || colon.location == 0) return invalid;
        NSString* key = [line substringToIndex:colon.location].lowercaseString;
        if(headers[key] || [key rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) return invalid;
        headers[key] = [[line substringFromIndex:NSMaxRange(colon)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    }
    if(![headers[@"host"] isEqual:host])
        return TerminalA2AProblem(400, @"invalid_request", @"Host must match the loopback address and port in the Agent Card URL.");
    if(headers[@"transfer-encoding"] || headers[@"expect"]) return invalid;
    NSString* length = headers[@"content-length"];
    if(length && !length.length) return invalid;
    NSUInteger bodyLength = 0;
    for(NSUInteger index = 0; index < length.length; ++index) {
        unichar digit = [length characterAtIndex:index];
        if(digit < '0' || digit > '9') return invalid;
        bodyLength = bodyLength * 10 + digit - '0';
        if(bodyLength > bodyLimit) return TerminalA2AProblem(413, @"request_too_large", @"Request body exceeds the limit.");
    }
    NSUInteger offset = NSMaxRange(boundary);
    NSUInteger end = offset + bodyLength;
    if(buffer.length > end) return invalid;
    while(buffer.length < end)
        if(!receive(fd, buffer, end, deadline)) return invalid;
    return request(start[0], start[1], headers, [buffer subdataWithRange:NSMakeRange(offset, bodyLength)], deadline);
}

void respond(int fd, NSDictionary* result, double deadline) {
    BOOL problem = [result[@"status"] isKindOfClass:NSNumber.class];
    NSInteger status = problem ? [result[@"status"] integerValue] : 200;
    NSString* phrase = @"OK";
    if(problem) {
        NSDictionary* statuses = @{
            @400: @[@"Bad Request", @"INVALID_ARGUMENT"], @401: @[@"Unauthorized", @"UNAUTHENTICATED"],
            @404: @[@"Not Found", @"NOT_FOUND"], @409: @[@"Conflict", @"ALREADY_EXISTS"],
            @410: @[@"Gone", @"FAILED_PRECONDITION"], @413: @[@"Content Too Large", @"RESOURCE_EXHAUSTED"],
            @503: @[@"Service Unavailable", @"UNAVAILABLE"],
        };
        NSArray* http = statuses[@(status)];
        phrase = http[0];
        NSDictionary* reasons = @{
            @"content_type_not_supported": @"CONTENT_TYPE_NOT_SUPPORTED", @"task_not_found": @"TASK_NOT_FOUND",
            @"task_not_cancelable": @"TASK_NOT_CANCELABLE", @"unsupported_operation": @"UNSUPPORTED_OPERATION",
            @"version_not_supported": @"VERSION_NOT_SUPPORTED",
        };
        NSString* code = result[@"code"];
        NSMutableDictionary* error = [@{ @"code": @(status), @"status": http[1], @"message": result[@"detail"] } mutableCopy];
        if([@[@"task_not_cancelable", @"unsupported_operation", @"version_not_supported"] containsObject:code])
            error[@"status"] = @"FAILED_PRECONDITION";
        if([code isEqual:@"queue_full"]) error[@"status"] = @"RESOURCE_EXHAUSTED";
        if(NSString* reason = reasons[code])
            error[@"details"] = @[@{ @"@type": @"type.googleapis.com/google.rpc.ErrorInfo",
                                     @"reason": reason, @"domain": @"a2a-protocol.org" }];
        result = @{ @"error": error };
    }
    NSData* data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    if(!data) return;
    NSString* header = [NSString stringWithFormat:
        @"HTTP/1.1 %ld %@\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\nCache-Control: no-store\r\n%@\r\n",
        (long)status, phrase,
        (unsigned long)data.length, status == 401 ? @"WWW-Authenticate: Bearer\r\n" : @""];
    if(sendData(fd, [header dataUsingEncoding:NSASCIIStringEncoding], deadline)) sendData(fd, data, deadline);
}
}

NSDictionary* TerminalA2AProblem(NSInteger status, NSString* code, NSString* detail) {
    return @{ @"status": @(status), @"code": code, @"detail": detail };
}

@implementation TerminalA2AHTTP {
    dispatch_source_t _listener;
}

- (instancetype)initWithRequest:(TerminalA2ARequest)request {
    if(!(self = [super init])) return nil;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if(fd < 0) return nil;
    editor_context::configure_socket(fd);
    sockaddr_in address = { sizeof(sockaddr_in), AF_INET, 0, { htonl(INADDR_LOOPBACK) } };
    socklen_t length = sizeof(address);
    if(fcntl(fd, F_SETFL, O_NONBLOCK) < 0 || bind(fd, (sockaddr*)&address, length) ||
       listen(fd, 8) || getsockname(fd, (sockaddr*)&address, &length)) {
        close(fd);
        return nil;
    }

    NSString* host = [NSString stringWithFormat:@"127.0.0.1:%u", ntohs(address.sin_port)];
    _origin = [@"http://" stringByAppendingString:host];
    dispatch_queue_t queue = dispatch_queue_create("org.textmate.a2a.http", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t slots = dispatch_semaphore_create(8);
    _listener = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, queue);
    if(!_listener) { close(fd); return nil; }
    __weak dispatch_source_t weakListener = _listener;
    dispatch_source_set_cancel_handler(_listener, ^{ close(fd); });
    dispatch_source_set_event_handler(_listener, ^{
        int client = accept(fd, nullptr, nullptr);
        if(client < 0) {
            if(dispatch_source_t source = weakListener; source && (errno == EMFILE || errno == ENFILE)) {
                dispatch_suspend(source);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), queue, ^{ dispatch_resume(source); });
            }
            return;
        }
        if(dispatch_semaphore_wait(slots, DISPATCH_TIME_NOW)) { close(client); return; }
        editor_context::configure_socket(client);
        double deadline = editor_context::now() + editor_context::request_timeout;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                NSDictionary* result = requestFromSocket(client, host, request, deadline);
                respond(client, result, deadline);
                close(client);
                dispatch_semaphore_signal(slots);
            }
        });
    });
    dispatch_resume(_listener);
    return self;
}

- (void)stop {
    if(_listener) dispatch_source_cancel(_listener);
    _listener = nil;
}
- (void)dealloc { [self stop]; }

@end
