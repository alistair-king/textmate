#import "EditorContextService.h"
#import "EditorContextBuffer.h"
#import <EditorContextProtocol.h>
#import <Cocoa/Cocoa.h>
#import <document/OakDocument.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <fcntl.h>

@interface EditorContextSnapshot ()
@property (copy) NSDictionary* (^renderer)(double);
@end
@implementation EditorContextSnapshot
+ (instancetype)response:(NSDictionary*)response { return [self renderer:^NSDictionary*(double){ return response; }]; }
+ (instancetype)renderer:(NSDictionary* (^)(double))renderer {
    EditorContextSnapshot* snapshot = [[self alloc] init];
    snapshot.renderer = renderer;
    return snapshot;
}
- (NSDictionary*)renderBefore:(double)deadline {
    if(editor_context::now() >= deadline) return editor_context::failure(@"The editor request timed out.", @"timeout");
    return _renderer(deadline);
}
@end

@interface EditorContextService ()
@property NSMutableDictionary<NSString*, NSDictionary*>* registrations;
@property NSMapTable<id, NSNumber*>* contentGenerations;
@property NSString* socketPath;
@property NSString* socketDirectory;
@property dispatch_source_t listener;
@end

@implementation EditorContextService
+ (instancetype)sharedService {
    static EditorContextService* service;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ service = [[self alloc] init]; });
    return service;
}
- (instancetype)init {
    if((self = [super init])) {
        _registrations = [NSMutableDictionary dictionary];
        _contentGenerations = [NSMapTable weakToStrongObjectsMapTable];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(contentDidChange:) name:OakDocumentContentDidChangeNotification object:nil];
        // /tmp keeps sockaddr_un within macOS's short path limit.
        char directory[] = "/tmp/textmate-context.XXXXXX";
        if(!mkdtemp(directory)) return self;
        _socketDirectory = @(directory);
        _socketPath = [_socketDirectory stringByAppendingPathComponent:@"context.sock"];
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un address = {};
        address.sun_family = AF_UNIX;
        strlcpy(address.sun_path, _socketPath.fileSystemRepresentation, sizeof(address.sun_path));
        if(fd < 0 || bind(fd, (struct sockaddr*)&address, sizeof(address)) || chmod(address.sun_path, 0600) || listen(fd, 8)) {
            if(fd >= 0) close(fd);
            unlink(address.sun_path);
            rmdir(directory);
            _socketPath = nil;
            return self;
        }
        fcntl(fd, F_SETFD, FD_CLOEXEC);
        fcntl(fd, F_SETFL, O_NONBLOCK);
        dispatch_queue_t queue = dispatch_queue_create("org.textmate.editor-context", DISPATCH_QUEUE_SERIAL);
        _listener = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, queue);
        __weak EditorContextService* weakSelf = self;
        dispatch_semaphore_t slots = dispatch_semaphore_create(8);
        dispatch_source_set_event_handler(_listener, ^{
            int client = accept(fd, nullptr, nullptr);
            if(client < 0) return;
            if(dispatch_semaphore_wait(slots, DISPATCH_TIME_NOW)) { close(client); return; }
            double deadline = editor_context::now() + editor_context::request_timeout;
            editor_context::configure_socket(client);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                @autoreleasepool {
                    NSDictionary* request = editor_context::parse(editor_context::read_line(client, deadline));
                    __block EditorContextSnapshot* snapshot;
                    dispatch_semaphore_t captured = dispatch_semaphore_create(0);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if(editor_context::now() < deadline) snapshot = [weakSelf snapshotForRequest:request];
                        dispatch_semaphore_signal(captured);
                    });
                    int64_t remaining = MAX(0.0, deadline - editor_context::now()) * NSEC_PER_SEC;
                    NSDictionary* response = nil;
                    if(dispatch_semaphore_wait(captured, dispatch_time(DISPATCH_TIME_NOW, remaining)) == 0)
                        response = [snapshot renderBefore:deadline];
                    response = response ?: editor_context::failure(@"The editor request timed out.", @"timeout");
                    editor_context::write_json(client, response, deadline);
                    close(client);
                    dispatch_semaphore_signal(slots);
                }
            });
        });
        dispatch_source_set_cancel_handler(_listener, ^{ close(fd); });
        dispatch_resume(_listener);
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(shutdown) name:NSApplicationWillTerminateNotification object:nil];
    }
    return self;
}
- (void)contentDidChange:(NSNotification*)notification {
    id document = notification.object;
    [EditorContextBuffer invalidateDocument:document];
    [_contentGenerations setObject:@([[_contentGenerations objectForKey:document] unsignedIntegerValue] + 1) forKey:document];
}
- (NSUInteger)contentGenerationForDocument:(id)document {
    return [[_contentGenerations objectForKey:document] unsignedIntegerValue];
}
- (void)shutdown {
    [_registrations removeAllObjects];
    if(_listener) dispatch_source_cancel(_listener);
    if(_socketPath) unlink(_socketPath.fileSystemRepresentation);
    if(_socketDirectory) rmdir(_socketDirectory.fileSystemRepresentation);
    _socketPath = nil;
}
- (NSDictionary*)environmentForSession:(NSUUID*)session provider:(EditorContextProvider)provider {
    NSAssert(NSThread.isMainThread, @"Register editor context on the main thread");
    if(!_socketPath || !provider) return @{};
    NSString* key = session.UUIDString;
    NSString* token = _registrations[key][@"token"] ?: [NSUUID.UUID.UUIDString stringByAppendingString:NSUUID.UUID.UUIDString];
    _registrations[key] = @{ @"token": token, @"provider": [provider copy] };
    return @{ @"TM_CONTEXT_SOCKET": _socketPath, @"TM_CONTEXT_SESSION": key, @"TM_CONTEXT_TOKEN": token };
}
- (void)revokeSession:(NSUUID*)session {
    NSAssert(NSThread.isMainThread, @"Revoke editor context on the main thread");
    [_registrations removeObjectForKey:session.UUIDString];
}
- (EditorContextSnapshot*)snapshotForRequest:(NSDictionary*)request {
    NSString* session = request[@"session"];
    NSString* token = request[@"token"];
    NSString* method = request[@"method"];
    NSDictionary* arguments = request[@"arguments"];
    if(![session isKindOfClass:NSString.class] || ![token isKindOfClass:NSString.class] ||
       ![method isKindOfClass:NSString.class] || ![arguments isKindOfClass:NSDictionary.class])
        return [EditorContextSnapshot response:editor_context::failure(@"Invalid context request", @"invalid_request")];
    NSDictionary* entry = _registrations[session];
    if(!entry || ![entry[@"token"] isEqual:token]) return [EditorContextSnapshot response:editor_context::failure(@"This terminal session has closed or its credentials are invalid.", @"session_unavailable")];
    EditorContextProvider provider = entry[@"provider"];
    return provider(method, arguments) ?: [EditorContextSnapshot response:editor_context::failure(@"The editor window has closed.", @"window_closed")];
}
@end
