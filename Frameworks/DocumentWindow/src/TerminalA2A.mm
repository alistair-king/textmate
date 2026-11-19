#import "TerminalA2A.h"
#import "TerminalA2AHTTP.h"
#import <EditorContextProtocol.h>
#include <signal.h>

namespace {
NSString* const cardPath = @"/.well-known/agent-card.json";
NSString* const submitted = @"TASK_STATE_SUBMITTED";
NSString* const working = @"TASK_STATE_WORKING";
NSString* const completed = @"TASK_STATE_COMPLETED";
NSString* const failed = @"TASK_STATE_FAILED";
NSString* const rejected = @"TASK_STATE_REJECTED";
NSString* const canceled = @"TASK_STATE_CANCELED";
NSString* const httpSender = @"http";
constexpr NSUInteger routeLimit = 64;
constexpr NSUInteger taskLimit = 32;

NSString* uuid() { return NSUUID.UUID.UUIDString.lowercaseString; }

BOOL active(NSDictionary* task) {
    NSString* state = task[@"status"][@"state"];
    return [state isEqual:submitted] || [state isEqual:working];
}

NSISO8601DateFormatter* timestampFormatter() {
    static NSISO8601DateFormatter* formatter = [] {
        NSISO8601DateFormatter* result = [[NSISO8601DateFormatter alloc] init];
        result.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        return result;
    }();
    return formatter;
}

void updateStatus(NSMutableDictionary* task, NSString* state, NSString* reason = nil) {
    NSMutableDictionary* status = [@{ @"state": state, @"timestamp": [timestampFormatter() stringFromDate:NSDate.date] } mutableCopy];
    if(reason) status[@"message"] = @{
        @"messageId": uuid(), @"role": @"ROLE_AGENT", @"taskId": task[@"id"], @"contextId": task[@"contextId"],
        @"parts": @[@{ @"text": reason }],
    };
    task[@"status"] = status;
}

BOOL validBearer(NSString* authorization, NSString* bearer) {
    if(authorization.length < 7 || [[authorization substringToIndex:7] caseInsensitiveCompare:@"Bearer "] != NSOrderedSame) return NO;
    NSString* value = [authorization substringFromIndex:7];
    if(value.length != bearer.length) return NO;
    unsigned difference = 0;
    for(NSUInteger i = 0; i < bearer.length; ++i)
        difference |= [value characterAtIndex:i] ^ [bearer characterAtIndex:i];
    return difference == 0;
}

// These query parameters are nonnegative int32 values in the A2A binding.
NSInteger queryInteger(id value, NSInteger defaultValue) {
    if(!value) return defaultValue;
    if(![value isKindOfClass:NSString.class] || ![value length]) return -1;
    int64_t number = 0;
    for(NSUInteger i = 0; i < [value length]; ++i) {
        unichar digit = [value characterAtIndex:i];
        if(digit < '0' || digit > '9') return -1;
        number = 10 * number + digit - '0';
        if(number > INT32_MAX) return -1;
    }
    return number;
}

NSMutableDictionary* taskResponse(NSDictionary* task, NSInteger historyLength, BOOL includeArtifacts = YES) {
    NSMutableDictionary* response = [task mutableCopy];
    if(historyLength == 0) [response removeObjectForKey:@"history"];
    if(!includeArtifacts) [response removeObjectForKey:@"artifacts"];
    return response;
}

NSString* taskCursor(NSDictionary* task) {
    return [NSString stringWithFormat:@"%@/%@", task[@"status"][@"timestamp"], task[@"id"]];
}
}

@interface TerminalA2ATask : NSObject
@property NSDictionary* senderMessage;
@property NSString* sender;
@property NSMutableDictionary* value;
// Automatic reviews are claimed only by the helper's background worker and
// manual (explicit card or HTTP) reviews only by the terminal's agent.
@property BOOL background;
@end
@implementation TerminalA2ATask
@end

@interface TerminalA2ARoute : NSObject
@property NSString* identifier;
@property NSString* terminal;
@property NSString* bearer;
@property NSString* credentialFile;
@property pid_t peer;
@property NSString* projectPath;
@property NSString* projectId;
@property BOOL automatic;
@property dispatch_source_t watch;
@property NSMutableArray<TerminalA2ATask*>* tasks;
@end
@implementation TerminalA2ARoute
@end

@implementation TerminalA2A {
    NSString* _directory;
    TerminalA2AHTTP* _http;
    NSMutableArray<TerminalA2ARoute*>* _routes;
    NSMutableDictionary<NSString*, TerminalA2ARoute*>* _reviewers;
}

- (instancetype)initWithDirectory:(NSString*)directory {
    if((self = [super init])) {
        _directory = [directory copy];
        _routes = [NSMutableArray array];
        _reviewers = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSString*)endpoint:(TerminalA2ARoute*)route {
    return [NSString stringWithFormat:@"%@/agents/%@", _http.origin, route.identifier];
}

- (NSString*)cardURL:(TerminalA2ARoute*)route {
    return [[self endpoint:route] stringByAppendingString:cardPath];
}

- (BOOL)startListener {
    if(_http) return YES;
    __weak TerminalA2A* weakSelf = self;
    _http = [[TerminalA2AHTTP alloc] initWithRequest:^NSDictionary*(NSString* method, NSString* target, NSDictionary* headers, NSData* body, double deadline) {
        NSDictionary* request = editor_context::parse(body);
        if(body.length && !request) return TerminalA2AProblem(400, @"invalid_request", @"Expected a JSON object.");
        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        __block NSDictionary* result;
        dispatch_async(dispatch_get_main_queue(), ^{
            TerminalA2A* gateway = weakSelf;
            if(gateway && gateway->_http && editor_context::now() < deadline)
                result = [gateway handleHTTP:method target:target headers:headers body:request];
            dispatch_semaphore_signal(finished);
        });
        double remaining = MAX(0.0, deadline - editor_context::now());
        if(dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, remaining * NSEC_PER_SEC)) != 0)
            return TerminalA2AProblem(503, @"unavailable", @"TextMate did not respond before the request deadline.");
        return result ?: TerminalA2AProblem(503, @"unavailable", @"TextMate is shutting down.");
    }];
    return _http != nil;
}

- (void)retire:(TerminalA2ARoute*)route {
    if(!route.watch) return;
    dispatch_source_cancel(route.watch);
    route.watch = nil;
    if(_reviewers[route.terminal] == route) [_reviewers removeObjectForKey:route.terminal];
    unlink(route.credentialFile.fileSystemRepresentation);
    for(TerminalA2ATask* task in route.tasks)
        if(active(task.value)) updateStatus(task.value, failed, @"The receiving terminal or MCP session closed.");
}

- (void)revokeSession:(NSString*)session {
    [self retire:_reviewers[session]];
}

- (void)shutdown {
    for(TerminalA2ARoute* route in _routes) [self retire:route];
    [_http stop];
    _http = nil;
    [_routes removeAllObjects];
}

- (TerminalA2ARoute*)enroll:(NSString*)terminal peer:(pid_t)peer {
    if(peer <= 0 || kill(peer, 0) != 0) return nil;
    TerminalA2ARoute* old = _reviewers[terminal];
    if(old && old.peer == peer) return old;
    if(old) {
        if(kill(old.peer, 0) == 0 || errno != ESRCH) return nil;
        [self retire:old];
    }
    if(_routes.count >= routeLimit) {
        NSUInteger retired = [_routes indexOfObjectPassingTest:^BOOL(TerminalA2ARoute* route, NSUInteger _, BOOL* stop) {
            return !route.watch;
        }];
        if(retired == NSNotFound) return nil;
        [_routes removeObjectAtIndex:retired];
    }
    TerminalA2ARoute* route = [[TerminalA2ARoute alloc] init];
    route.identifier = uuid();
    route.terminal = terminal;
    route.peer = peer;
    route.bearer = [uuid() stringByAppendingString:uuid()];
    route.credentialFile = [_directory stringByAppendingPathComponent:[NSString stringWithFormat:@"a2a-%@.token", route.identifier]];
    route.tasks = [NSMutableArray array];
    int fd = open(route.credentialFile.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if(fd < 0) return nil;
    NSData* data = [route.bearer dataUsingEncoding:NSASCIIStringEncoding];
    BOOL written = write(fd, data.bytes, data.length) == (ssize_t)data.length;
    close(fd);
    if(!written) { unlink(route.credentialFile.fileSystemRepresentation); return nil; }

    route.watch = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, peer, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
    if(!route.watch) { unlink(route.credentialFile.fileSystemRepresentation); return nil; }
    __weak TerminalA2A* weakSelf = self;
    __weak TerminalA2ARoute* weakRoute = route;
    dispatch_source_set_event_handler(route.watch, ^{ [weakSelf retire:weakRoute]; });
    dispatch_source_set_registration_handler(route.watch, ^{
        if(kill(peer, 0) != 0 && errno == ESRCH) [weakSelf retire:weakRoute];
    });
    _reviewers[terminal] = route;
    [_routes addObject:route];
    dispatch_resume(route.watch);
    if(kill(peer, 0) != 0 && errno == ESRCH) { [self retire:route]; return nil; }
    return route;
}

- (NSDictionary*)card:(TerminalA2ARoute*)route {
    return @{
        @"name": @"TextMate terminal reviewer",
        @"description": @"Review a supplied diff asynchronously in an opted-in TextMate terminal. Set configuration.returnImmediately to true.",
        @"version": @"1.0",
        @"supportedInterfaces": @[@{ @"url": [self endpoint:route], @"protocolBinding": @"HTTP+JSON", @"protocolVersion": @"1.0" }],
        @"capabilities": @{ @"streaming": @NO, @"pushNotifications": @NO, @"extendedAgentCard": @NO },
        @"securitySchemes": @{ @"localBearer": @{ @"httpAuthSecurityScheme": @{ @"scheme": @"Bearer" } } },
        @"securityRequirements": @[@{ @"schemes": @{ @"localBearer": @{ @"list": @[] } } }],
        @"defaultInputModes": @[@"text/plain"], @"defaultOutputModes": @[@"text/plain"],
        @"skills": @[@{ @"id": @"review-diff", @"name": @"Review a diff",
            @"description": @"Return findings with file and line references. Submit up to 64 KiB of UTF-8 text with returnImmediately enabled.",
            @"tags": @[@"code-review"] }],
    };
}

- (NSDictionary*)submit:(NSDictionary*)request route:(TerminalA2ARoute*)route sender:(NSString*)sender background:(BOOL)background {
    NSDictionary* config = request[@"configuration"];
    id immediate = [config isKindOfClass:NSDictionary.class] ? config[@"returnImmediately"] : nil;
    if(immediate != (__bridge id)kCFBooleanTrue)
        return TerminalA2AProblem(400, @"unsupported_operation", @"Use configuration.returnImmediately=true.");
    NSDictionary* message = request[@"message"];
    if(![message isKindOfClass:NSDictionary.class] || ![message[@"role"] isEqual:@"ROLE_USER"] ||
       !editor_context::identifier(message[@"messageId"]) || message[@"taskId"] || message[@"contextId"])
        return TerminalA2AProblem(400, @"invalid_request", @"Expected a new ROLE_USER message with a messageId.");
    NSArray* parts = message[@"parts"];
    if(![parts isKindOfClass:NSArray.class] || parts.count == 0 || parts.count > 8)
        return TerminalA2AProblem(400, @"invalid_request", @"Expected one to eight text parts.");
    NSUInteger length = 0;
    NSMutableArray* textParts = [NSMutableArray arrayWithCapacity:parts.count];
    for(NSDictionary* part in parts) {
        if(![part isKindOfClass:NSDictionary.class] || part[@"raw"] || part[@"url"] || part[@"data"] ||
           ![part[@"text"] isKindOfClass:NSString.class])
            return TerminalA2AProblem(400, @"content_type_not_supported", @"Each part must contain text and no other content field.");
        NSString* mediaType = part[@"mediaType"];
        if(mediaType && (![mediaType isKindOfClass:NSString.class] || ![mediaType.lowercaseString hasPrefix:@"text/"] || mediaType.length == 5))
            return TerminalA2AProblem(400, @"content_type_not_supported", @"Only text media types are supported.");
        NSString* text = part[@"text"];
        length += [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if(length > editor_context::a2a_text_limit)
            return TerminalA2AProblem(413, @"request_too_large", @"Review text exceeds 64 KiB in UTF-8 bytes.");
        if(!editor_context::a2a_text(text))
            return TerminalA2AProblem(400, @"invalid_request", @"Text parts must contain nonempty UTF-8 text.");
        [textParts addObject:@{ @"text": text }];
    }
    message = @{ @"messageId": message[@"messageId"], @"role": @"ROLE_USER", @"parts": [textParts copy] };
    for(TerminalA2ATask* task in route.tasks) {
        if(![task.sender isEqual:sender] || ![task.senderMessage[@"messageId"] isEqual:message[@"messageId"]]) continue;
        if(![task.senderMessage isEqual:message] || task.background != background)
            return TerminalA2AProblem(409, @"message_id_conflict", @"messageId already refers to a different message or delivery mode.");
        return @{ @"task": [task.value copy] };
    }
    if(!route.watch) return TerminalA2AProblem(410, @"reviewer_unavailable", @"The reviewer is unavailable.");
    if(route.tasks.count >= taskLimit) {
        NSUInteger finished = [route.tasks indexOfObjectPassingTest:^BOOL(TerminalA2ATask* task, NSUInteger _, BOOL* stop) {
            return !active(task.value);
        }];
        if(finished == NSNotFound) return TerminalA2AProblem(503, @"queue_full", @"The reviewer queue is full.");
        [route.tasks removeObjectAtIndex:finished];
    }
    NSString* taskID = uuid(), *context = uuid();
    TerminalA2ATask* task = [[TerminalA2ATask alloc] init];
    task.sender = sender;
    task.senderMessage = message;
    task.background = background;
    NSMutableDictionary* history = [message mutableCopy];
    history[@"taskId"] = taskID;
    history[@"contextId"] = context;
    task.value = [@{ @"id": taskID, @"contextId": context, @"history": @[[history copy]] } mutableCopy];
    updateStatus(task.value, submitted);
    [route.tasks addObject:task];
    return @{ @"task": [task.value copy] };
}

- (NSDictionary*)task:(NSString*)taskID route:(TerminalA2ARoute*)route sender:(NSString*)sender cancel:(BOOL)cancel {
    for(TerminalA2ATask* task in route.tasks)
        if([task.sender isEqual:sender] && [task.value[@"id"] isEqual:taskID]) {
            if(cancel && ![task.value[@"status"][@"state"] isEqual:canceled]) {
                if(!active(task.value)) return TerminalA2AProblem(400, @"task_not_cancelable", @"Only a queued or in-progress task can be canceled.");
                updateStatus(task.value, canceled);
            }
            return [task.value copy];
        }
    return TerminalA2AProblem(404, @"task_not_found", @"Task not found.");
}

- (NSDictionary*)listTasks:(TerminalA2ARoute*)route query:(NSDictionary*)query {
    NSInteger pageSize = queryInteger(query[@"pageSize"], 50);
    NSInteger historyLength = queryInteger(query[@"historyLength"], 0);
    id includeArtifactsValue = query[@"includeArtifacts"] ?: @"false";
    if(pageSize < 1 || pageSize > 100 || historyLength < 0 || ![@[@"true", @"false"] containsObject:includeArtifactsValue])
        return TerminalA2AProblem(400, @"invalid_request", @"Invalid pageSize, historyLength, or includeArtifacts.");
    BOOL includeArtifacts = [includeArtifactsValue isEqual:@"true"];
    NSString* state = query[@"status"];
    NSArray* states = @[submitted, working, completed, failed, rejected, canceled, @"TASK_STATE_UNSPECIFIED",
                        @"TASK_STATE_INPUT_REQUIRED", @"TASK_STATE_AUTH_REQUIRED"];
    if([state isKindOfClass:NSString.class] && ![state hasPrefix:@"TASK_STATE_"])
        state = [@"TASK_STATE_" stringByAppendingString:state.uppercaseString];
    if(state && ![states containsObject:state]) return TerminalA2AProblem(400, @"invalid_request", @"Invalid task status.");

    NSDate* after = nil;
    if(id value = query[@"statusTimestampAfter"]) {
        if([value isKindOfClass:NSString.class]) {
            after = [timestampFormatter() dateFromString:value];
            if(!after) {
                static NSISO8601DateFormatter* wholeSeconds = [[NSISO8601DateFormatter alloc] init];
                after = [wholeSeconds dateFromString:value];
            }
        }
        if(!after) return TerminalA2AProblem(400, @"invalid_request", @"statusTimestampAfter must be an ISO 8601 timestamp.");
    }
    NSString* cursor = nil;
    if(id token = query[@"pageToken"]; token && ![token isEqual:@""]) {
        NSData* decoded = [token isKindOfClass:NSString.class] ? [[NSData alloc] initWithBase64EncodedString:token options:0] : nil;
        if(decoded) cursor = [[NSString alloc] initWithData:decoded encoding:NSASCIIStringEncoding];
        NSArray* components = [cursor componentsSeparatedByString:@"/"];
        if(components.count != 2 || ![timestampFormatter() dateFromString:components[0]] || ![[NSUUID alloc] initWithUUIDString:components[1]])
            return TerminalA2AProblem(400, @"invalid_request", @"Invalid pageToken.");
    }

    NSMutableArray<NSDictionary*>* matching = [NSMutableArray array];
    for(TerminalA2ATask* task in route.tasks) {
        NSDictionary* status = task.value[@"status"];
        if(![task.sender isEqual:httpSender] || (state && ![status[@"state"] isEqual:state]) ||
           (query[@"contextId"] && ![task.value[@"contextId"] isEqual:query[@"contextId"]]) ||
           (after && [[timestampFormatter() dateFromString:status[@"timestamp"]] compare:after] == NSOrderedAscending)) continue;
        [matching addObject:task.value];
    }
    [matching sortUsingComparator:^NSComparisonResult(NSDictionary* left, NSDictionary* right) {
        return [taskCursor(right) compare:taskCursor(left) options:NSLiteralSearch];
    }];
    NSMutableArray* page = [NSMutableArray array];
    NSString* next = @"";
    NSString* last = nil;
    for(NSDictionary* task in matching) {
        NSString* key = taskCursor(task);
        if(cursor && [key compare:cursor options:NSLiteralSearch] != NSOrderedAscending) continue;
        if(page.count == (NSUInteger)pageSize) {
            next = [[last dataUsingEncoding:NSASCIIStringEncoding] base64EncodedStringWithOptions:0];
            break;
        }
        NSMutableDictionary* response = taskResponse(task, historyLength, includeArtifacts);
        if(includeArtifacts && !response[@"artifacts"]) response[@"artifacts"] = @[];
        [page addObject:response];
        last = key;
    }
    return @{ @"tasks": page, @"nextPageToken": next, @"pageSize": @(pageSize), @"totalSize": @(matching.count) };
}

- (NSDictionary*)handleHTTP:(NSString*)method target:(NSString*)target headers:(NSDictionary*)headers body:(NSDictionary*)body {
    NSURLComponents* url = [NSURLComponents componentsWithString:target];
    NSArray* segments = [url.percentEncodedPath componentsSeparatedByString:@"/"];
    if(segments.count < 4 || ![segments[1] isEqual:@"agents"])
        return TerminalA2AProblem(404, @"not_found", @"Endpoint not found.");
    TerminalA2ARoute* route;
    for(TerminalA2ARoute* candidate in _routes)
        if([candidate.identifier isEqual:segments[2]]) { route = candidate; break; }
    if(!route) return TerminalA2AProblem(404, @"not_found", @"Reviewer not found.");
    NSMutableDictionary* query = [NSMutableDictionary dictionary];
    for(NSURLQueryItem* item in url.queryItems) {
        if(query[item.name]) return TerminalA2AProblem(400, @"invalid_request", @"Query parameters must appear at most once.");
        query[item.name] = item.value ?: @"";
    }
    NSString* version = headers[@"a2a-version"] ?: query[@"A2A-Version"];
    NSString* suffix = [[segments subarrayWithRange:NSMakeRange(3, segments.count - 3)] componentsJoinedByString:@"/"];
    BOOL isCard = [method isEqual:@"GET"] && [suffix isEqual:[cardPath substringFromIndex:1]];
    if((version || !isCard) && ![version isEqual:@"1.0"])
        return TerminalA2AProblem(400, @"version_not_supported", @"Set A2A-Version to 1.0.");
    if(isCard) {
        if(!route.watch) return TerminalA2AProblem(410, @"reviewer_unavailable", @"The reviewer is unavailable.");
        return [self card:route];
    }
    if(!validBearer(headers[@"authorization"], route.bearer))
        return TerminalA2AProblem(401, @"unauthenticated", @"A reviewer bearer credential is required.");
    if([method isEqual:@"POST"] && [suffix isEqual:@"message:send"])
        return body ? [self submit:body route:route sender:httpSender background:NO] : TerminalA2AProblem(400, @"invalid_request", @"Expected a JSON object.");
    if([method isEqual:@"GET"] && [suffix isEqual:@"tasks"])
        return [self listTasks:route query:query];
    if(segments.count == 5 && [segments[3] isEqual:@"tasks"]) {
        NSString* taskID = segments[4];
        if([method isEqual:@"GET"]) {
            NSInteger historyLength = queryInteger(query[@"historyLength"], -2);
            if(historyLength == -1) return TerminalA2AProblem(400, @"invalid_request", @"historyLength must be a nonnegative integer.");
            NSDictionary* result = [self task:taskID route:route sender:httpSender cancel:NO];
            return [result[@"status"] isKindOfClass:NSDictionary.class] ? taskResponse(result, historyLength) : result;
        }
        if([method isEqual:@"POST"] && [taskID hasSuffix:@":cancel"]) {
            taskID = [taskID substringToIndex:taskID.length - [@":cancel" length]];
            return [self task:taskID route:route sender:httpSender cancel:YES];
        }
    }
    return TerminalA2AProblem(400, @"unsupported_operation", @"This loopback endpoint supports asynchronous review submission, task retrieval, listing, and cancellation.");
}

- (NSDictionary*)perform:(NSString*)method arguments:(NSDictionary*)arguments
                 session:(NSString*)session peer:(pid_t)peer provider:(EditorContextProvider)provider {
    NSAssert(NSThread.isMainThread, @"Handle A2A requests on the main thread");
    if(NSString* invalid = editor_context::validate_arguments(method, arguments))
        return editor_context::failure(invalid, @"invalid_arguments");
    BOOL send = [method isEqual:@"a2a_send_review"];
    BOOL cancel = [method isEqual:@"a2a_cancel_task"];
    TerminalA2ARoute* sender = _reviewers[session];
    if([method isEqual:@"a2a_list_reviewers"]) {
        NSMutableArray* reviewers = [NSMutableArray array];
        for(TerminalA2ARoute* route in _routes) {
            if(!route.watch || !sender.projectId || ![route.projectId isEqual:sender.projectId]) continue;
            [reviewers addObject:@{ @"cardUrl": [self cardURL:route], @"projectPath": route.projectPath,
                @"automatic": @(route.automatic), @"ownSession": @([route.terminal isEqual:session]) }];
        }
        return @{ @"reviewers": reviewers };
    }
    BOOL discover = send && !arguments[@"cardUrl"];
    // A sender's messageId names one submission across every route, so both delivery
    // paths resolve it before choosing a route and the verdict cannot depend on order.
    TerminalA2ARoute* priorRoute = nil;
    TerminalA2ATask* prior = nil;
    if(send && arguments[@"messageId"]) {
        for(TerminalA2ARoute* candidate in _routes) {
            for(TerminalA2ATask* task in candidate.tasks)
                if([task.sender isEqual:session] && [task.senderMessage[@"messageId"] isEqual:arguments[@"messageId"]]) { prior = task; break; }
            if(prior) { priorRoute = candidate; break; }
        }
        if(prior && (prior.background != discover || (!discover && ![[self cardURL:priorRoute] isEqual:arguments[@"cardUrl"]])))
            return editor_context::failure(@"messageId already refers to a different message, reviewer, or delivery mode.", @"message_id_conflict");
    }
    if(discover) {
        if(!sender.projectId || sender.peer != peer)
            return editor_context::failure(@"Register this session with its project before requesting automatic review.", @"reviewer_unavailable");
        // Retries stay on the original route, even if another worker is now available
        // or the original one has since retired: its retained task is the answer.
        TerminalA2ARoute* selected = priorRoute;
        if(!selected) {
            NSUInteger bestLoad = NSUIntegerMax;
            for(TerminalA2ARoute* candidate in _routes) {
                if(!candidate.watch || !candidate.automatic || ![candidate.projectId isEqual:sender.projectId]) continue;
                NSUInteger pending = 0;
                for(TerminalA2ATask* task in candidate.tasks) if(active(task.value)) ++pending;
                if(pending >= taskLimit) continue;
                NSUInteger load = pending * 2 + ([candidate.terminal isEqual:session] ? 1 : 0);
                if(load < bestLoad) { selected = candidate; bestLoad = load; }
            }
        }
        if(!selected) return editor_context::failure(@"No automatic reviewer is connected for this project. Install Codex CLI and reconnect a TextMate agent.", @"reviewer_unavailable");
        NSMutableDictionary* resolved = [arguments mutableCopy];
        resolved[@"cardUrl"] = [self cardURL:selected];
        arguments = resolved;
    }
    if(send || cancel || [method isEqual:@"a2a_get_task"]) {
        for(TerminalA2ARoute* route in _routes) {
            if(![[self cardURL:route] isEqual:arguments[@"cardUrl"]]) continue;
            NSDictionary* result;
            if(!send) result = [self task:arguments[@"taskId"] route:route sender:session cancel:cancel];
            else result = [self submit:@{
                @"configuration": @{ @"returnImmediately": @YES },
                @"message": @{ @"messageId": arguments[@"messageId"] ?: uuid(), @"role": @"ROLE_USER", @"parts": @[@{ @"text": arguments[@"review"] }] },
            } route:route sender:session background:discover];
            if([result[@"status"] isKindOfClass:NSNumber.class]) return editor_context::failure(result[@"detail"], result[@"code"]);
            if(discover && result[@"task"]) {
                TerminalA2ATask* submittedTask = nil;
                for(TerminalA2ATask* task in route.tasks)
                    if([task.value[@"id"] isEqual:result[@"task"][@"id"]]) submittedTask = task;
                if(submittedTask && !submittedTask.value[@"metadata"])
                    submittedTask.value[@"metadata"] = @{ @"textmate": @{ @"sourceDirectory": sender.projectPath } };
                return @{ @"cardUrl": [self cardURL:route], @"task": [submittedTask.value copy] ?: result[@"task"] };
            }
            return result;
        }
        return editor_context::failure(@"Use an Agent Card URL from this TextMate instance.", @"reviewer_unavailable");
    }

    TerminalA2ARoute* route = _reviewers[session];
    BOOL background = [method isEqual:editor_context::a2a_background_claim] || [method isEqual:editor_context::a2a_background_reply];
    if([method isEqual:@"a2a_reply"] || [method isEqual:editor_context::a2a_background_reply]) {
        if(!route || route.peer != peer) return editor_context::failure(@"Opt in from this MCP session first.", @"reviewer_unavailable");
        NSString* outcome = arguments[@"outcome"];
        NSString* nextState = [outcome isEqual:@"rejected"] ? rejected : [outcome isEqual:@"failed"] ? failed : completed;
        for(TerminalA2ATask* task in route.tasks) {
            if(task.background != background || ![task.value[@"id"] isEqual:arguments[@"taskId"]]) continue;
            NSString* findings = arguments[@"findings"];
            NSString* state = task.value[@"status"][@"state"];
            if([state isEqual:nextState]) {
                NSString* prior = [state isEqual:completed] ? task.value[@"artifacts"][0][@"parts"][0][@"text"] :
                    task.value[@"status"][@"message"][@"parts"][0][@"text"];
                if([prior isEqual:findings]) return [task.value copy];
            }
            if(![state isEqual:working]) return editor_context::failure(@"Only an in-progress task can receive a reply.", @"invalid_task_state");
            if([nextState isEqual:completed])
                task.value[@"artifacts"] = @[@{ @"artifactId": uuid(), @"name": @"Review findings", @"parts": @[@{ @"text": findings }] }];
            updateStatus(task.value, nextState, [nextState isEqual:completed] ? nil : findings);
            return [task.value copy];
        }
        return editor_context::failure(@"Task not found for this reviewer.", @"task_not_found");
    }

    NSDictionary* window = [provider(@"get_connection_status", @{}) renderBefore:editor_context::now() + editor_context::request_timeout];
    if(!window[@"windowId"]) return editor_context::failure(@"The terminal window is unavailable.", @"window_closed");
    if([method isEqual:@"a2a_opt_in"]) {
        if(![self startListener] || !(route = [self enroll:session peer:peer]))
            return editor_context::failure(@"Could not register a local reviewer.", @"reviewer_unavailable");
        if(arguments[@"projectPath"]) {
            route.projectPath = arguments[@"projectPath"];
            route.projectId = arguments[@"projectId"];
            route.automatic = [arguments[@"automatic"] boolValue];
        }
        return @{ @"cardUrl": [self cardURL:route], @"windowId": window[@"windowId"], @"credentialFile": route.credentialFile };
    }
    if(!route || route.peer != peer) return editor_context::failure(@"Opt in from this MCP session first.", @"reviewer_unavailable");
    if(arguments[@"taskId"]) {
        for(TerminalA2ATask* task in route.tasks)
            if(task.background == background && [task.value[@"id"] isEqual:arguments[@"taskId"]])
                return @{ @"task": [task.value copy], @"windowId": window[@"windowId"] };
        return editor_context::failure(@"Task not found for this reviewer.", @"task_not_found");
    }
    for(NSString* state in @[working, submitted]) {
        for(TerminalA2ATask* task in route.tasks) {
            if(task.background != background || ![task.value[@"status"][@"state"] isEqual:state]) continue;
            if([state isEqual:submitted]) updateStatus(task.value, working);
            return @{ @"task": [task.value copy], @"windowId": window[@"windowId"] };
        }
    }
    return @{ @"task": NSNull.null, @"windowId": window[@"windowId"] };
}

@end
