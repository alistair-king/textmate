#import "../src/TerminalA2A.h"
#import <EditorContextProtocol.h>

// Replace only the listener so queue routing can be tested inside environments
// that prohibit bind(). Production HTTP interoperability has separate tests.
@interface RoutingTestHTTP : NSObject
@property(readonly) NSString* origin;
- (void)stop;
@end
@implementation RoutingTestHTTP
- (NSString*)origin { return @"http://127.0.0.1:12345"; }
- (void)stop {}
@end
@interface RoutingTestGateway : TerminalA2A
- (BOOL)startListener;
@end
@implementation RoutingTestGateway
- (BOOL)startListener {
    [self setValue:[[RoutingTestHTTP alloc] init] forKey:@"http"];
    return YES;
}
@end

static void require(bool condition, NSString* message) {
    if(!condition) { fprintf(stderr, "%s\n", message.UTF8String); exit(1); }
}

int main() {
    @autoreleasepool {
        char pattern[] = "/tmp/textmate-routing-test-XXXXXX";
        require(mkdtemp(pattern) != nullptr, @"Could not create fixture directory.");
        TerminalA2A* gateway = [[RoutingTestGateway alloc] initWithDirectory:@(pattern)];
        auto query = [&](NSString* session, NSString* method, NSDictionary* arguments = @{}) {
            return [gateway perform:method arguments:arguments session:session peer:getpid()
                provider:^EditorContextSnapshot*(NSString*, NSDictionary*) {
                    return [EditorContextSnapshot response:@{ @"windowId": @"routing-test" }];
                }];
        };
        for(NSString* session in @[@"sender", @"peer", @"unrelated"]) {
            NSDictionary* result = query(session, @"a2a_opt_in", @{
                @"projectPath": [session isEqual:@"sender"] ? @"/tmp/source" : @"/tmp/reviewer",
                @"projectId": [session isEqual:@"unrelated"] ? @"other-repository" : @"shared-git-directory",
                @"automatic": @YES });
            require(result[@"cardUrl"] != nil, @"Registration failed.");
        }
        require([query(@"sender", @"a2a_list_reviewers")[@"reviewers"] count] == 2, @"Discovery crossed project boundaries.");
        NSDictionary* request = @{ @"review": @"A fixed diff.", @"messageId": @"stable-diff" };
        NSDictionary* submitted = query(@"sender", @"a2a_send_review", request);
        require(submitted[@"cardUrl"] != nil, @"Automatic selection failed.");
        require([query(@"sender", @"a2a_send_review", request) isEqual:submitted], @"A retry created a duplicate task.");
        NSString* background = editor_context::a2a_background_claim;
        require(query(@"sender", background)[@"task"] == NSNull.null, @"Idle peer was not preferred.");
        require(query(@"unrelated", background)[@"task"] == NSNull.null, @"Task leaked into another project.");
        require(query(@"peer", @"a2a_claim")[@"task"] == NSNull.null, @"The agent claimed an automatic review.");
        NSDictionary* claimed = query(@"peer", background)[@"task"];
        require([claimed[@"id"] isEqual:submitted[@"task"][@"id"]], @"Wrong review claimed.");
        require([claimed[@"metadata"][@"textmate"][@"sourceDirectory"] isEqual:@"/tmp/source"], @"Source worktree was lost.");
        require([query(@"peer", @"a2a_claim", @{ @"taskId": claimed[@"id"] })[@"code"] isEqual:@"task_not_found"], @"The agent read a background review.");
        require([query(@"peer", @"a2a_reply", @{ @"taskId": claimed[@"id"], @"findings": @"Agent findings.", @"outcome": @"completed" })[@"code"]
            isEqual:@"task_not_found"], @"The agent answered a background review.");
        require([query(@"sender", @"a2a_send_review", @{
            @"review": @"Another diff.", @"messageId": @"stable-diff" })[@"code"] isEqual:@"message_id_conflict"], @"Conflicting retry was accepted.");
        NSDictionary* lookup = @{ @"cardUrl": submitted[@"cardUrl"], @"taskId": claimed[@"id"] };
        require([query(@"unrelated", @"a2a_get_task", lookup)[@"code"] isEqual:@"task_not_found"], @"Another sender read a private task.");
        query(@"sender", @"a2a_cancel_task", lookup);
        require([query(@"peer", background, @{ @"taskId": claimed[@"id"] })[@"task"][@"status"][@"state"]
            isEqual:@"TASK_STATE_CANCELED"], @"Worker could not observe cancellation.");
        // A manually addressed review waits for the terminal's agent, never the background worker.
        NSDictionary* manual = query(@"sender", @"a2a_send_review", @{
            @"review": @"A manual diff.", @"messageId": @"manual-diff", @"cardUrl": submitted[@"cardUrl"] });
        require(manual[@"task"][@"id"] != nil, @"Manual submission failed.");
        require([query(@"sender", @"a2a_send_review", @{ @"review": @"A manual diff.", @"messageId": @"manual-diff" })[@"code"]
            isEqual:@"message_id_conflict"], @"Reusing a manual messageId for automatic review was accepted.");
        require(query(@"peer", background)[@"task"] == NSNull.null, @"The background worker claimed a manual review.");
        require([query(@"peer", @"a2a_claim")[@"task"][@"id"] isEqual:manual[@"task"][@"id"]], @"The agent could not claim its manual review.");
        require(query(@"peer", background)[@"task"] == NSNull.null, @"The background worker recovered the agent's claimed review.");
        // The reverse order: an automatic submission's messageId cannot be reused on any explicit card.
        NSDictionary* automatic = query(@"sender", @"a2a_send_review", @{ @"review": @"An automatic diff.", @"messageId": @"automatic-diff" });
        require(automatic[@"task"][@"id"] != nil, @"Automatic submission failed.");
        for(NSString* card in @[submitted[@"cardUrl"], automatic[@"cardUrl"]])
            require([query(@"sender", @"a2a_send_review", @{ @"review": @"An automatic diff.", @"messageId": @"automatic-diff", @"cardUrl": card })[@"code"]
                isEqual:@"message_id_conflict"], @"An explicit submission reused an automatic messageId.");
        query(@"sender", @"a2a_cancel_task", @{ @"cardUrl": automatic[@"cardUrl"], @"taskId": automatic[@"task"][@"id"] });
        [gateway revokeSession:@"peer"];
        // The original reviewer has retired, but the sender's retry still names its retained task.
        NSDictionary* retried = query(@"sender", @"a2a_send_review", request);
        require([retried[@"task"][@"id"] isEqual:claimed[@"id"]], @"A retry after the reviewer retired launched a second review.");
        require(query(@"sender", background)[@"task"] == NSNull.null, @"A retry queued a duplicate on another worker.");
        NSDictionary* fallback = query(@"sender", @"a2a_send_review", @{ @"review": @"A new diff." });
        require([query(@"sender", background)[@"task"][@"id"] isEqual:fallback[@"task"][@"id"]], @"Single-session fallback failed.");
        [gateway revokeSession:@"sender"];
        require([query(@"sender", @"a2a_send_review", request)[@"code"] isEqual:@"reviewer_unavailable"], @"Retired sender remained discoverable.");
        [gateway shutdown];
        [NSFileManager.defaultManager removeItemAtPath:@(pattern) error:nil];
        puts("Automatic reviewer project isolation, delivery modes, retries, cancellation, and retirement passed.");
    }
}
