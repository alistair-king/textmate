#import <Cocoa/Cocoa.h>
#import <EditorContextProtocol.h>
#import "../src/EditorContextService.h"
#import "../src/EditorContextBuffer.h"
#import "../src/SelectionExplanation.h"
#import "../src/TerminalPanelViewController.h"
#import "../src/DocumentWindowController.h"
#import <OakTextView/OakTextView.h>
#import <document/OakDocument.h>
#include <sys/un.h>

#import "EditorContextTestAccess.h"

static NSDictionary* context_test_query(NSDictionary* environment) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    editor_context::configure_socket(fd);
    sockaddr_un address = {};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, [environment[@"TM_CONTEXT_SOCKET"] fileSystemRepresentation], sizeof(address.sun_path));
    OAK_ASSERT(connect(fd, (sockaddr*)&address, sizeof(address)) == 0);
    editor_context::write_json(fd, @{ @"session": environment[@"TM_CONTEXT_SESSION"], @"token": environment[@"TM_CONTEXT_TOKEN"],
                                     @"method": @"get_editor_context", @"arguments": @{} });
    NSDictionary* result = editor_context::parse(editor_context::read_line(fd));
    close(fd);
    return result;
}

void test_editor_context_session_routing_and_revocation ()
{
    @autoreleasepool {
        __block NSDictionary* environment;
        NSUUID* session = NSUUID.UUID;
        dispatch_sync(dispatch_get_main_queue(), ^{
            environment = [EditorContextService.sharedService environmentForSession:session provider:^EditorContextSnapshot*(NSString* method, NSDictionary* arguments){ return [EditorContextSnapshot response:@{ @"window": @"first" }]; }];
        });
        OAK_ASSERT([context_test_query(environment)[@"window"] isEqual:@"first"]);
        NSMutableDictionary* forged = [environment mutableCopy];
        forged[@"TM_CONTEXT_TOKEN"] = @"wrong";
        OAK_ASSERT(context_test_query(forged)[@"error"] != nil);
        dispatch_sync(dispatch_get_main_queue(), ^{
            NSDictionary* moved = [EditorContextService.sharedService environmentForSession:session provider:^EditorContextSnapshot*(NSString* method, NSDictionary* arguments){ return [EditorContextSnapshot response:@{ @"window": @"second" }]; }];
            OAK_ASSERT([moved isEqual:environment]);
        });
        OAK_ASSERT([context_test_query(environment)[@"window"] isEqual:@"second"]);
        dispatch_sync(dispatch_get_main_queue(), ^{ [EditorContextService.sharedService revokeSession:session]; });
        OAK_ASSERT(context_test_query(environment)[@"error"] != nil);
    }
}

void test_editor_context_live_buffers_and_unicode ()
{
    __block DocumentWindowController* window;
    __block OakDocument* document;
    __block BOOL loaded = NO;
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    dispatch_sync(dispatch_get_main_queue(), ^{
        [NSApplication sharedApplication];
        [DocumentWindowController disableSessionSave];
        window = [[DocumentWindowController alloc] init];
        document = [OakDocument documentWithString:@"one\nA😀B\nlast" fileType:@"text.plain" customName:@"context test"];
        [document loadModalForWindow:nil completionHandler:^(OakDocumentIOResult status, NSString*, oak::uuid_t const&){
            loaded = status == OakDocumentIOResultSuccess;
            dispatch_semaphore_signal(ready);
        }];
    });
    OAK_ASSERT(dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
    OAK_ASSERT(loaded);
    dispatch_sync(dispatch_get_main_queue(), ^{ @autoreleasepool {
        [window setDocuments:@[document]];
        [window setSelectedDocument:document];
        window.textView.selectionString = @"2:2-2:6";
        NSDictionary* context = [window testEditorContextForMethod:@"get_editor_context" arguments:@{}];
        OAK_ASSERT([context[@"document"][@"documentId"] isEqual:document.identifier.UUIDString]);
        OAK_ASSERT([context[@"selections"][0][@"text"] isEqual:@"😀"]);
        OAK_ASSERT([context[@"cursor"][@"offset"] unsignedIntegerValue] == 7);
        window.textView.selectionString = @"2:6-2:2";
        context = [window testEditorContextForMethod:@"get_editor_context" arguments:@{}];
        OAK_ASSERT([context[@"cursor"][@"offset"] unsignedIntegerValue] == 5);
        window.textView.selectionString = @"1:1-1:4&3:1-3:5";
        context = [window testEditorContextForMethod:@"get_editor_context" arguments:@{}];
        OAK_ASSERT([context[@"selections"] count] == 2);
        OAK_ASSERT([context[@"selections"][0][@"text"] isEqual:@"one"]);
        OAK_ASSERT([context[@"selections"][1][@"text"] isEqual:@"last"]);
        NSDictionary* read = [window testEditorContextForMethod:@"read_document" arguments:@{ @"documentId": document.identifier.UUIDString, @"offset": @5, @"length": @2 }];
        OAK_ASSERT([read[@"text"] isEqual:@"😀"]);
        OAK_ASSERT([read[@"nextOffset"] unsignedIntegerValue] == 7);
        OAK_ASSERT(([window testEditorContextForMethod:@"read_document" arguments:@{ @"documentId": document.identifier.UUIDString, @"offset": @6 }][@"error"] != nil));
        OAK_ASSERT([window testEditorContextForMethod:@"read_document" arguments:@{ @"documentId": NSUUID.UUID.UUIDString }][@"error"] != nil);
        id revision = read[@"document"][@"revision"];
        document.content = @"changed without saving";
        read = [window testEditorContextForMethod:@"read_document" arguments:@{ @"documentId": document.identifier.UUIDString }];
        OAK_ASSERT([read[@"text"] isEqual:@"changed without saving"]);
        OAK_ASSERT(![read[@"document"][@"revision"] isEqual:revision]);
        document.content = @"ab\ncd\nef";
        window.textView.selectionString = @"1:1x3:2";
        context = [window testEditorContextForMethod:@"get_editor_context" arguments:@{}];
        OAK_ASSERT([context[@"selections"] count] == 3);
        OAK_ASSERT([context[@"selections"][0][@"text"] isEqual:@"a"]);
        OAK_ASSERT([context[@"selections"][1][@"text"] isEqual:@"c"]);
        OAK_ASSERT([context[@"selections"][2][@"text"] isEqual:@"e"]);
        [window setSelectedDocument:nil];
        OAK_ASSERT([window testEditorContextForMethod:@"get_editor_context" arguments:@{}][@"document"] == NSNull.null);
        [window setDocuments:@[]];
        [document close];
        [window close];
        [DocumentWindowController enableSessionSave];
    } });
}

void test_selection_explanation_snapshot_and_validation ()
{
    __block DocumentWindowController* window;
    __block OakDocument* document;
    __block EditorContextSnapshot* snapshot;
    __block BOOL loaded = NO;
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    dispatch_sync(dispatch_get_main_queue(), ^{
        [NSApplication sharedApplication];
        [DocumentWindowController disableSessionSave];
        window = [[DocumentWindowController alloc] init];
        document = [OakDocument documentWithString:@"one\nA😀B\nlast" fileType:@"text.plain" customName:@"unsaved selection"];
        [document loadModalForWindow:nil completionHandler:^(OakDocumentIOResult status, NSString*, oak::uuid_t const&){
            loaded = status == OakDocumentIOResultSuccess;
            dispatch_semaphore_signal(ready);
        }];
    });
    OAK_ASSERT(dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)) == 0 && loaded);
    dispatch_sync(dispatch_get_main_queue(), ^{
        [window setDocuments:@[document]];
        [window setSelectedDocument:document];
        NSMenuItem* action = [[NSMenuItem alloc] initWithTitle:@"Explain Selection…" action:NSSelectorFromString(@"explainSelection:") keyEquivalent:@""];
        window.textView.selectionString = @"1:1";
        OAK_ASSERT(![window validateMenuItem:action]);
        window.textView.selectionString = @"1:1-1:4&2:2-2:6";
        OAK_ASSERT([window validateMenuItem:action]);
        snapshot = [window editorContextForMethod:@"get_editor_context" arguments:@{}];
        document.content = @"edited after invoking Explain Selection";
    });
    NSString* error = nil;
    NSString* prompt = SelectionExplanationPrompt([snapshot renderBefore:editor_context::now()+3], &error);
    OAK_ASSERT(prompt != nil && error == nil);
    NSRange start = [prompt rangeOfString:@"\n\n{" options:NSBackwardsSearch];
    OAK_ASSERT(start.location != NSNotFound);
    NSDictionary* excerpt = editor_context::parse([[prompt substringFromIndex:start.location+2] dataUsingEncoding:NSUTF8StringEncoding]);
    OAK_ASSERT([excerpt[@"document"][@"name"] isEqual:@"unsaved selection"]);
    OAK_ASSERT(excerpt[@"document"][@"path"] == NSNull.null);
    OAK_ASSERT([excerpt[@"selections"] count] == 2);
    OAK_ASSERT([excerpt[@"selections"][0][@"text"] isEqual:@"one"]);
    OAK_ASSERT([excerpt[@"selections"][1][@"text"] isEqual:@"😀"]);
    OAK_ASSERT([excerpt[@"selections"][1][@"start"][@"line"] integerValue] == 2);
    for(NSString* agent in @[@"codex", @"claude", @"opencode"])
        OAK_ASSERT([SelectionExplanationArguments(agent, prompt).lastObject isEqual:prompt]);
    OAK_ASSERT(SelectionExplanationArguments(@"unknown", prompt) == nil);
    OAK_ASSERT(SelectionExplanationPrompt(@{ @"document": @{}, @"selections": @[@{ @"text": @"" }] }, &error) == nil && error != nil);
    OAK_ASSERT(SelectionExplanationPrompt(@{ @"document": @{}, @"selections": @[@{ @"text": @"partial", @"truncated": @YES }] }, &error) == nil);
    OAK_ASSERT(SelectionExplanationPrompt(@{ @"document": @{}, @"selectionsTruncated": @YES, @"selections": @[] }, &error) == nil);
    OAK_ASSERT(SelectionExplanationPrompt(@{ @"error": @"The editor request timed out." }, &error) == nil);
    dispatch_sync(dispatch_get_main_queue(), ^{
        [window setSelectedDocument:nil];
        [window setDocuments:@[]];
        [document close];
        [window close];
        [DocumentWindowController enableSessionSave];
    });
}

void test_editor_context_large_immutable_snapshot ()
{
    __block OakDocument* document;
    __block EditorContextBuffer* snapshot;
    __block BOOL loaded = NO;
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    NSUInteger repetitions = 200000;
    NSString* original = [@"abc😀\n" stringByPaddingToLength:repetitions*6 withString:@"abc😀\n" startingAtIndex:0];
    dispatch_sync(dispatch_get_main_queue(), ^{
        document = [OakDocument documentWithString:original fileType:@"text.plain" customName:@"large snapshot"];
        [document loadModalForWindow:nil completionHandler:^(OakDocumentIOResult status, NSString*, oak::uuid_t const&){
            loaded = status == OakDocumentIOResultSuccess;
            dispatch_semaphore_signal(ready);
        }];
    });
    OAK_ASSERT(dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
    OAK_ASSERT(loaded);
    dispatch_sync(dispatch_get_main_queue(), ^{
        snapshot = [EditorContextBuffer bufferForDocument:document revision:@"test-before-edit"];
        document.content = @"edited after snapshot";
    });
    // Render on this worker thread after the live document changed.
    NSDictionary* read = [snapshot responseForMethod:@"read_document" arguments:@{ @"offset": @(repetitions*6-12), @"length": @12 }
        base:@{} document:@{} ranges:ng::ranges_t() caret:0 deadline:editor_context::now()+3];
    OAK_ASSERT([read[@"text"] isEqual:@"abc😀\nabc😀\n"]);
    OAK_ASSERT([read[@"totalLength"] unsignedIntegerValue] == repetitions*6);
    OAK_ASSERT(![read[@"truncated"] boolValue]);
    ng::ranges_t rectangle(ng::range_t(0, (repetitions-1)*8+1, true));
    NSDictionary* context = [snapshot responseForMethod:@"get_editor_context" arguments:@{} base:@{} document:@{}
        ranges:rectangle caret:repetitions*8 deadline:editor_context::now()+3];
    OAK_ASSERT([context[@"selections"] count] == 128);
    OAK_ASSERT([context[@"selectionsTruncated"] boolValue]);
    OAK_ASSERT([context[@"selections"][127][@"text"] isEqual:@"a"]);
    OAK_ASSERT([context[@"cursor"][@"offset"] unsignedIntegerValue] == repetitions*6);
    OAK_ASSERT([context[@"cursor"][@"line"] unsignedIntegerValue] == repetitions+1);
    NSDictionary* timeout = [snapshot responseForMethod:@"read_document" arguments:@{} base:@{} document:@{}
        ranges:ng::ranges_t() caret:0 deadline:editor_context::now()-1];
    OAK_ASSERT([timeout[@"code"] isEqual:@"timeout"]);
    dispatch_sync(dispatch_get_main_queue(), ^{ [document close]; });
}

void test_editor_context_real_terminal_transfer_and_window_close ()
{
    __block DocumentWindowController* first;
    __block DocumentWindowController* second;
    __block OakDocument* firstDocument;
    __block OakDocument* secondDocument;
    __block NSDictionary* firstEnvironment;
    __block NSDictionary* secondEnvironment;
    __block TerminalPanelViewController* firstPanel;
    __block TerminalPanelViewController* secondPanel;
    __block NSUUID* movedSession;
    dispatch_group_t loaded = dispatch_group_create();
    __block BOOL success = YES;
    dispatch_sync(dispatch_get_main_queue(), ^{
        [NSApplication sharedApplication];
        [DocumentWindowController disableSessionSave];
        first = [[DocumentWindowController alloc] init];
        second = [[DocumentWindowController alloc] init];
        firstDocument = [OakDocument documentWithString:@"first window unsaved" fileType:@"text.plain" customName:@"first document"];
        secondDocument = [OakDocument documentWithString:@"second window unsaved" fileType:@"text.plain" customName:@"second document"];
        for(OakDocument* document in @[firstDocument, secondDocument]) {
            dispatch_group_enter(loaded);
            [document loadModalForWindow:nil completionHandler:^(OakDocumentIOResult status, NSString*, oak::uuid_t const&){
                success = success && status == OakDocumentIOResultSuccess;
                dispatch_group_leave(loaded);
            }];
        }
    });
    OAK_ASSERT(dispatch_group_wait(loaded, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)) == 0);
    OAK_ASSERT(success);
    dispatch_sync(dispatch_get_main_queue(), ^{
        [first setDocuments:@[firstDocument]]; [first setSelectedDocument:firstDocument];
        [second setDocuments:@[secondDocument]]; [second setSelectedDocument:secondDocument];
        firstPanel = [first valueForKey:@"terminalPanelController"];
        secondPanel = [second valueForKey:@"terminalPanelController"];
        [firstPanel startTerminalInDirectory:NSTemporaryDirectory()];
        [secondPanel startTerminalInDirectory:NSTemporaryDirectory()];
        movedSession = [[firstPanel valueForKey:@"terminalController"] valueForKey:@"sessionIdentifiers"][0];
        NSUUID* secondSession = [[secondPanel valueForKey:@"terminalController"] valueForKey:@"sessionIdentifiers"][0];
        firstEnvironment = firstPanel.contextEnvironmentProvider(movedSession);
        secondEnvironment = secondPanel.contextEnvironmentProvider(secondSession);
    });
    __block NSDictionary* firstResult;
    __block NSDictionary* secondResult;
    dispatch_group_t queries = dispatch_group_create();
    dispatch_group_async(queries, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ firstResult = context_test_query(firstEnvironment); });
    dispatch_group_async(queries, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ secondResult = context_test_query(secondEnvironment); });
    OAK_ASSERT(dispatch_group_wait(queries, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)) == 0);
    OAK_ASSERT([firstResult[@"document"][@"documentId"] isEqual:firstDocument.identifier.UUIDString]);
    OAK_ASSERT([secondResult[@"document"][@"documentId"] isEqual:secondDocument.identifier.UUIDString]);
    dispatch_sync(dispatch_get_main_queue(), ^{
        [secondPanel takeTerminalSession:movedSession fromPanel:firstPanel];
        [first close];
    });
    OAK_ASSERT([context_test_query(firstEnvironment)[@"document"][@"documentId"] isEqual:secondDocument.identifier.UUIDString]);
    dispatch_sync(dispatch_get_main_queue(), ^{
        [second close];
        [firstDocument close]; [secondDocument close];
        [DocumentWindowController enableSessionSave];
    });
    OAK_ASSERT([context_test_query(firstEnvironment)[@"code"] isEqual:@"session_unavailable"]);
    OAK_ASSERT([context_test_query(secondEnvironment)[@"code"] isEqual:@"session_unavailable"]);
}
