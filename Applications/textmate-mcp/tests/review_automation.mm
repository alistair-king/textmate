#import <Foundation/Foundation.h>
#import <EditorContextProtocol.h>
#include <mutex>
#include <signal.h>

// Exercise the production worker and real subprocess lifecycle without opening
// a socket or invoking a model. The socket protocol has separate integration tests.
static std::mutex stateMutex;
static NSMutableDictionary* currentTask;
static NSDictionary* enrolled;
static int replyFailures = 0;
static NSString* replyFailureCode = @"timeout";
static std::atomic<int> replyAttempts{0};
static bool foregroundUsed = false;
namespace editor_context {
static NSDictionary* query(NSString* method, NSDictionary* arguments) {
    std::lock_guard<std::mutex> lock(stateMutex);
    if([method isEqual:@"a2a_opt_in"]) {
        enrolled = arguments;
        return @{ @"cardUrl": @"test-card" };
    }
    if([method isEqual:@"a2a_send_review"]) {
        currentTask = [@{ @"id": @"test-task", @"status": @{ @"state": @"TASK_STATE_SUBMITTED" },
            @"history": @[@{ @"parts": @[@{ @"text": arguments[@"review"] }] }] } mutableCopy];
        return @{ @"cardUrl": @"test-card", @"task": [currentTask copy] };
    }
    if([method isEqual:@"a2a_claim"] || [method isEqual:@"a2a_reply"]) {
        foregroundUsed = true;
        return failure(@"The worker must not use the agent's claim or reply.");
    }
    if([method isEqual:a2a_background_claim]) {
        if(arguments[@"taskId"]) return @{ @"task": [currentTask copy] ?: NSNull.null };
        NSString* state = currentTask[@"status"][@"state"];
        if([state isEqual:@"TASK_STATE_SUBMITTED"]) currentTask[@"status"] = @{ @"state": @"TASK_STATE_WORKING" };
        if(![@[@"TASK_STATE_SUBMITTED", @"TASK_STATE_WORKING"] containsObject:state ?: @""]) return @{ @"task": NSNull.null };
        return @{ @"task": [currentTask copy] };
    }
    if([method isEqual:@"a2a_get_task"]) return [currentTask copy];
    if([method isEqual:@"a2a_cancel_task"]) {
        currentTask[@"status"] = @{ @"state": @"TASK_STATE_CANCELED" };
        return [currentTask copy];
    }
    if([method isEqual:a2a_background_reply]) {
        if(replyAttempts++ < replyFailures) {
            // A revoked session retires its route, which fails the task it held.
            if([replyFailureCode isEqual:@"session_unavailable"]) currentTask[@"status"] = @{ @"state": @"TASK_STATE_FAILED" };
            return failure(@"The editor did not answer.", replyFailureCode);
        }
        if(![currentTask[@"status"][@"state"] isEqual:@"TASK_STATE_WORKING"])
            return failure(@"Task canceled.", @"invalid_task_state");
        currentTask[@"status"] = @{ @"state": [arguments[@"outcome"] isEqual:@"completed"] ? @"TASK_STATE_COMPLETED" : @"TASK_STATE_FAILED" };
        currentTask[@"artifacts"] = @[@{ @"parts": @[@{ @"text": arguments[@"findings"] }] }];
        return [currentTask copy];
    }
    return failure(@"Unexpected test method.");
}
}
#import "../src/ReviewAutomation.h"

static void require(bool condition, NSString* message) {
    if(!condition) { fprintf(stderr, "%s\n", message.UTF8String); exit(1); }
}

int main(int argc, char const* argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        NSString* scenario = argc > 1 ? @(argv[1]) : @"success";
        char pattern[] = "/tmp/textmate-review-test-XXXXXX";
        require(mkdtemp(pattern) != nullptr, @"Cannot create fixture directory.");
        NSString* directory = @(pattern);
        NSString* stub = [directory stringByAppendingPathComponent:@"codex"];
        NSString* proof = [directory stringByAppendingPathComponent:@"worker.json"];
        NSString* script = [NSString stringWithFormat:
            @"#!/usr/bin/python3\nimport json, os, pathlib, sys, time\n"
             "args = sys.argv[1:]\n"
             "prompt = sys.stdin.read()\n"
             "pathlib.Path('%@').write_text(json.dumps({'args': args, 'prompt': prompt, 'pid': os.getpid(), "
             "'cwd': os.getcwd(), 'credentials': [k for k in os.environ if k.startswith('TM_CONTEXT_')]}))\n"
             "if '%@' == 'failure': sys.exit(9)\n"
             "if '%@' in ('cancel', 'shutdown'): time.sleep(30)\n"
             "pathlib.Path(args[args.index('--output-last-message')+1]).write_text('example.cc:12 has a regression.')\n",
            proof, scenario, scenario];
        require([NSFileManager.defaultManager createFileAtPath:stub contents:[script dataUsingEncoding:NSUTF8StringEncoding]
            attributes:@{NSFilePosixPermissions: @0700}], @"Cannot create reviewer stub.");
        setenv("TM_A2A_AUTOMATIC", "1", 1);
        setenv("TM_A2A_PROJECT", directory.UTF8String, 1);
        setenv("TM_CODEX_COMMAND", [scenario isEqual:@"unavailable"] ? "/nonexistent/textmate-review-codex" : stub.UTF8String, 1);
        setenv("TM_CONTEXT_TOKEN", "test-secret", 1);
        if([scenario isEqual:@"redeliver"]) replyFailures = 2;
        if([scenario isEqual:@"session-gone"]) { replyFailures = 1000; replyFailureCode = @"session_unavailable"; }
        ReviewAutomation automation;
        automation.start();
        if([scenario isEqual:@"unavailable"]) {
            require(enrolled && ![enrolled[@"automatic"] boolValue], @"Missing Codex was advertised as an automatic reviewer.");
            automation.stop();
            [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
            puts("Missing reviewer registration passed.");
            return 0;
        }
        require([enrolled[@"automatic"] boolValue], @"Worker did not register automatically.");
        require([enrolled[@"projectPath"] isEqual:[directory stringByResolvingSymlinksInPath]], @"Wrong project registered.");
        std::atomic<bool> canceled{false};
        NSDictionary* result = nil;
        std::thread sender([&] { @autoreleasepool {
            result = automation.send(@{ @"review": @"FIXED DIFF CONTENT", @"messageId": @"stable-diff" }, canceled);
        } });
        double deadline = editor_context::now() + 10;
        while(![NSFileManager.defaultManager fileExistsAtPath:proof] && editor_context::now() < deadline) usleep(20000);
        NSDictionary* observed = editor_context::parse([NSData dataWithContentsOfFile:proof]);
        require(observed != nil, @"Reviewer did not start.");
        require([observed[@"credentials"] count] == 0, @"Reviewer inherited editor credentials.");
        require([observed[@"prompt"] containsString:@"FIXED DIFF CONTENT"], @"Reviewer did not receive the diff.");
        NSArray* arguments = observed[@"args"];
        NSUInteger sandbox = [arguments indexOfObject:@"--sandbox"];
        require(sandbox != NSNotFound && [arguments[sandbox + 1] isEqual:@"read-only"], @"Reviewer sandbox was not read-only.");
        NSUInteger exec = [arguments indexOfObject:@"exec"];
        require(exec != NSNotFound, @"Reviewer did not use exec.");
        NSArray* global = [arguments subarrayWithRange:NSMakeRange(0, exec)];
        NSArray* local = [arguments subarrayWithRange:NSMakeRange(exec, arguments.count - exec)];
        require([[global componentsJoinedByString:@" "] containsString:@"--disable plugins --disable apps"], @"Reviewer kept plugins or apps enabled.");
        require([local containsObject:@"--ignore-user-config"], @"Reviewer loaded the user's Codex configuration and its MCP servers.");
        require(![arguments containsObject:@"mcp_servers={}"], @"Reviewer relied on an empty table, which Codex merges.");
        if([scenario isEqual:@"session-gone"]) {
            double until = editor_context::now() + 5;
            while(replyAttempts == 0 && editor_context::now() < until) usleep(20000);
            usleep(1500000);
            require(replyAttempts == 1, @"Delivery kept retrying after the session was gone.");
        }
        if([scenario isEqual:@"cancel"]) canceled = true;
        if([scenario isEqual:@"shutdown"]) automation.stop();
        sender.join();
        if([scenario isEqual:@"session-gone"]) {
            replyFailures = 0;
            [NSFileManager.defaultManager removeItemAtPath:proof error:nil];
            std::atomic<bool> fresh{false};
            NSDictionary* next = automation.send(@{ @"review": @"SECOND DIFF", @"messageId": @"second-diff" }, fresh);
            require([next[@"task"][@"status"][@"state"] isEqual:@"TASK_STATE_COMPLETED"], @"Worker stopped claiming after its session was gone.");
        }
        if([scenario isEqual:@"redeliver"]) {
            require([result[@"task"][@"status"][@"state"] isEqual:@"TASK_STATE_COMPLETED"], @"Findings were not redelivered.");
            require(replyAttempts == 3, @"Delivery did not retry transport failures.");
            [NSFileManager.defaultManager removeItemAtPath:proof error:nil];
            NSDictionary* next = automation.send(@{ @"review": @"SECOND DIFF", @"messageId": @"second-diff" }, canceled);
            require([next[@"task"][@"status"][@"state"] isEqual:@"TASK_STATE_COMPLETED"], @"Worker stopped claiming after a delivery failure.");
            require([editor_context::parse([NSData dataWithContentsOfFile:proof])[@"prompt"] containsString:@"SECOND DIFF"], @"Second review did not run.");
        }
        automation.stop();
        require(!foregroundUsed, @"Worker claimed or replied through the agent's methods.");
        require(kill([observed[@"pid"] intValue], 0) != 0 && errno == ESRCH, @"Reviewer process survived cancellation or shutdown.");
        if([scenario isEqual:@"cancel"] || [scenario isEqual:@"shutdown"])
            require([result[@"code"] isEqual:@"review_timeout"], @"Cancellation did not propagate to the sender.");
        else {
            NSString* state = [@[@"failure", @"session-gone"] containsObject:scenario] ? @"TASK_STATE_FAILED" : @"TASK_STATE_COMPLETED";
            require([result[@"task"][@"status"][@"state"] isEqual:state], @"Worker result had an incorrect state.");
            if([scenario isEqual:@"success"])
                require([result[@"task"][@"artifacts"][0][@"parts"][0][@"text"] containsString:@"example.cc:12"], @"Findings did not reach the sender.");
        }
        NSString* promptPath = observed[@"args"][[arguments indexOfObject:@"--output-last-message"] + 1];
        require(![NSFileManager.defaultManager fileExistsAtPath:[promptPath stringByDeletingLastPathComponent]], @"Private review files were not removed.");
        [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
        printf("Automatic review %s passed.\n", scenario.UTF8String);
    }
}
