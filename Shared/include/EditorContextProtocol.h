#pragma once
#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>
#include <fcntl.h>
#include <chrono>

// Private, bounded, one-request-per-connection protocol. MCP itself uses stdio.
namespace editor_context {
constexpr size_t message_limit = 1024 * 1024;
constexpr double request_timeout = 3;
inline double now() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
inline bool wait_for(int fd, short events, double deadline) {
    while(now() < deadline) {
        pollfd descriptor = { fd, events, 0 };
        int status = poll(&descriptor, 1, MAX(1, (int)((deadline-now()) * 1000)));
        if(status < 0 && errno == EINTR) continue;
        if(status > 0 && (descriptor.revents & (events | POLLHUP))) return true;
        if(status > 0) return false;
    }
    errno = ETIMEDOUT;
    return false;
}
inline NSData* read_line(int fd, double deadline = now() + request_timeout) {
    NSMutableData* data = [NSMutableData data];
    char bytes[4096];
    while(data.length < message_limit && wait_for(fd, POLLIN, deadline)) {
        ssize_t n = recv(fd, bytes, MIN(sizeof(bytes), message_limit - data.length), MSG_DONTWAIT);
        if(n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if(n <= 0) return nil;
        char const* newline = static_cast<char const*>(memchr(bytes, '\n', n));
        [data appendBytes:bytes length:newline ? newline - bytes : n];
        if(newline) return data;
    }
    return nil;
}
inline bool write_json(int fd, id object, double deadline = now() + request_timeout) {
    NSData* encoded = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingWithoutEscapingSlashes error:nil];
    if(!encoded || encoded.length >= message_limit) return false;
    NSMutableData* data = [encoded mutableCopy];
    [data appendBytes:"\n" length:1];
    auto bytes = static_cast<char const*>(data.bytes);
    size_t left = data.length;
    int type;
    socklen_t size = sizeof(type);
    bool socket = getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &size) == 0;
    while(left && wait_for(fd, POLLOUT, deadline)) {
        size_t count = MIN(left, (size_t)4096);
        ssize_t n = socket ? send(fd, bytes, count, MSG_DONTWAIT) : write(fd, bytes, count);
        if(n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if(n <= 0) return false;
        bytes += n;
        left -= n;
    }
    return left == 0;
}
inline NSDictionary* parse(NSData* data) {
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
inline NSDictionary* failure(NSString* message, NSString* code = @"context_error") { return @{ @"error": message, @"code": code }; }
inline void configure_socket(int fd) {
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    fcntl(fd, F_SETFD, FD_CLOEXEC);
}
inline bool connect_socket(int fd, sockaddr_un const& address, double deadline) {
    int flags = fcntl(fd, F_GETFL);
    if(flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return false;
    int status = connect(fd, (sockaddr const*)&address, sizeof(address));
    if(status < 0 && errno == EINPROGRESS) {
        if(!wait_for(fd, POLLOUT, deadline)) return false;
        int error = 0;
        socklen_t length = sizeof(error);
        if(getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) || error) { if(error) errno = error; return false; }
    }
    else if(status < 0) return false;
    return true;
}
inline bool integer(id value, double maximum) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        [value doubleValue] >= 0 && [value doubleValue] <= maximum && floor([value doubleValue]) == [value doubleValue];
}
inline NSString* validate_arguments(NSString* method, NSDictionary* arguments) {
    if(![arguments isKindOfClass:NSDictionary.class]) return @"Expected object arguments";
    if([method isEqual:@"get_editor_context"] || [method isEqual:@"list_open_documents"] || [method isEqual:@"get_connection_status"])
        return arguments.count ? @"This tool takes no arguments" : nil;
    if(![method isEqual:@"read_document"]) return @"Unknown tool";
    for(NSString* key in arguments)
        if(![@[@"documentId", @"offset", @"length"] containsObject:key]) return @"Unknown argument";
    if(![arguments[@"documentId"] isKindOfClass:NSString.class] || ![arguments[@"documentId"] length]) return @"documentId is required";
    if(arguments[@"offset"] && !integer(arguments[@"offset"], 9007199254740991.0)) return @"offset must be a nonnegative integer";
    if(arguments[@"length"] && !integer(arguments[@"length"], 32768)) return @"length must be an integer between 0 and 32768";
    return nil;
}
}
