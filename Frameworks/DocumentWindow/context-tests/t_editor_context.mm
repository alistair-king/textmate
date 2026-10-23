#import <Cocoa/Cocoa.h>
#import <EditorContextProtocol.h>
#import "../src/EditorContextService.h"
#import "../src/EditorContextBuffer.h"
#import "../src/EditorContextDiagnostics.h"
#import "../src/SelectionExplanation.h"
#import "../src/TerminalPanelViewController.h"
#import "../src/DocumentWindowController.h"
#import <OakTextView/OakTextView.h>
#import <document/OakDocument.h>
#import <lsp/LSPManager.h>
#import <lsp/LSPClient.h>
#include <sys/un.h>

#import "EditorContextTestAccess.h"

static NSDictionary* context_test_query(NSDictionary* environment, NSString* method = @"get_editor_context", NSDictionary* arguments = @{}) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    editor_context::configure_socket(fd);
    sockaddr_un address = {};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, [environment[@"TM_CONTEXT_SOCKET"] fileSystemRepresentation], sizeof(address.sun_path));
    OAK_ASSERT(connect(fd, (sockaddr*)&address, sizeof(address)) == 0);
    editor_context::write_json(fd, @{ @"session": environment[@"TM_CONTEXT_SESSION"], @"token": environment[@"TM_CONTEXT_TOKEN"],
                                     @"method": method, @"arguments": arguments });
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

void test_editor_context_diagnostics_reports_and_window_boundary ()
{
    NSString* directory = [@"/tmp/tm-diagnostic-test-" stringByAppendingString:NSUUID.UUID.UUIDString];
    OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
    NSString* path = [directory stringByAppendingPathComponent:@"a file 😀.txt"];
    OAK_ASSERT([@"A😀B\nlast\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    __block DocumentWindowController* window;
    __block OakDocument* document;
    __block OakDocument* foreign;
    __block EditorContextSnapshot* snapshot;
    __block BOOL loaded = NO;
    __block NSString* capturedReport;
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    dispatch_sync(dispatch_get_main_queue(), ^{
        [NSApplication sharedApplication];
        [DocumentWindowController disableSessionSave];
        window = [[DocumentWindowController alloc] init];
        document = [OakDocument documentWithPath:path];
        document.fileType = @"text.plain";
        foreign = [OakDocument documentWithString:@"not in this window" fileType:@"text.plain" customName:@"foreign"];
        [document loadModalForWindow:nil completionHandler:^(OakDocumentIOResult status, NSString*, oak::uuid_t const&){
            loaded = status == OakDocumentIOResultSuccess;
            dispatch_semaphore_signal(ready);
        }];
    });
    OAK_ASSERT(dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)) == 0 && loaded);
    dispatch_sync(dispatch_get_main_queue(), ^{
        [window setDocuments:@[document]];
        [window setSelectedDocument:document];
        LSPManager* manager = LSPManager.sharedManager;
        NSDictionary* result = [window testEditorContextForMethod:@"get_diagnostics" arguments:@{}];
        OAK_ASSERT([result[@"status"] isEqual:@"unavailable"]);
        OAK_ASSERT(result[@"reportId"] == NSNull.null);
        ContextDiagnosticTestClient* client = [ContextDiagnosticTestClient new];
        client.running = client.initialized = YES;
        NSMutableDictionary* clients = [manager valueForKey:@"documentClients"];
        clients[document.identifier] = client;
        clients[foreign.identifier] = client;
        OAK_ASSERT([[manager diagnosticReportForDocument:foreign][@"status"] isEqual:@"unavailable"]);
        [clients removeObjectForKey:foreign.identifier];
        result = [window testEditorContextForMethod:@"get_diagnostics" arguments:@{}];
        OAK_ASSERT([result[@"status"] isEqual:@"pending"]);
        OAK_ASSERT([result[@"serverStatus"] isEqual:@"running"]);
        NSString* uri = [NSURL fileURLWithPath:path].absoluteString;
        [(id<LSPClientDelegate>)manager lspClient:nil didReceiveDiagnostics:@[] forDocumentURI:uri];
        result = [window testEditorContextForMethod:@"get_diagnostics" arguments:@{}];
        OAK_ASSERT([result[@"status"] isEqual:@"reported"] && [result[@"totalCount"] integerValue] == 0);
        NSString* emptyReport = result[@"reportId"];
        NSMutableArray* diagnostics = [NSMutableArray array];
        for(NSUInteger severity = 1; severity <= 4; ++severity)
            [diagnostics addObject:@{ @"line": @0, @"character": @3, @"endLine": @1, @"endCharacter": @2,
                                     @"severity": @(severity), @"message": @"diagnostic 😀", @"code": severity == 1 ? (id)@123 : @"TEST",
                                     @"source": @"test-server", @"data": @{ @"private": @"not exported" } }];
        [(id<LSPClientDelegate>)manager lspClient:nil didReceiveDiagnostics:diagnostics forDocumentURI:uri];
        [diagnostics removeAllObjects]; // The manager owns an immutable copy.
        result = [window testEditorContextForMethod:@"get_diagnostics" arguments:@{ @"limit": @2 }];
        OAK_ASSERT([result[@"diagnostics"] count] == 2);
        OAK_ASSERT([result[@"totalCount"] integerValue] == 4 && [result[@"truncated"] boolValue]);
        OAK_ASSERT([result[@"nextOffset"] integerValue] == 2);
        NSDictionary* first = result[@"diagnostics"][0];
        OAK_ASSERT([first[@"severity"] isEqual:@"error"] && [first[@"code"] integerValue] == 123);
        OAK_ASSERT([first[@"source"] isEqual:@"test-server"] && first[@"data"] == nil);
        OAK_ASSERT([first[@"range"][@"start"][@"line"] integerValue] == 1 && [first[@"range"][@"start"][@"column"] integerValue] == 4);
        OAK_ASSERT([first[@"location"] isEqual:[path stringByAppendingString:@":1"]]);
        OAK_ASSERT([result[@"freshness"] isEqual:@"unknown"]);
        capturedReport = result[@"reportId"];
        OAK_ASSERT(![capturedReport isEqual:emptyReport]);
        result = [window testEditorContextForMethod:@"get_diagnostics" arguments:@{ @"documentId": document.identifier.UUIDString, @"offset": @2, @"reportId": capturedReport }];
        OAK_ASSERT(![result[@"truncated"] boolValue] && [result[@"diagnostics"] count] == 2);
        OAK_ASSERT([result[@"diagnostics"][0][@"severity"] isEqual:@"information"]);
        OAK_ASSERT([result[@"diagnostics"][1][@"severity"] isEqual:@"hint"]);
        OAK_ASSERT([[window testEditorContextForMethod:@"get_diagnostics" arguments:@{ @"documentId": foreign.identifier.UUIDString }][@"code"] isEqual:@"document_unavailable"]);
        OAK_ASSERT([[window testEditorContextForMethod:@"get_diagnostics" arguments:@{ @"offset": @5 }][@"code"] isEqual:@"invalid_offset"]);
        snapshot = [window editorContextForMethod:@"get_diagnostics" arguments:@{ @"limit": @100 }];
        document.content = @"unsaved changes after capture";
        [(id<LSPClientDelegate>)manager lspClient:nil didReceiveDiagnostics:@[] forDocumentURI:uri];
        OAK_ASSERT([[window testEditorContextForMethod:@"get_diagnostics" arguments:@{ @"reportId": capturedReport }][@"code"] isEqual:@"diagnostics_changed"]);
        [clients removeObjectForKey:document.identifier];
    });
    NSDictionary* captured = [snapshot renderBefore:editor_context::now()+3];
    OAK_ASSERT([captured[@"diagnostics"] count] == 4 && [captured[@"reportId"] isEqual:capturedReport]);
    dispatch_sync(dispatch_get_main_queue(), ^{
        [window setSelectedDocument:nil];
        [window setDocuments:@[]];
        [document close];
        [foreign close];
        [window close];
        // These fixture reports have no real server lifecycle to clear them.
        NSString* uri = [NSURL fileURLWithPath:path].absoluteString;
        [[LSPManager.sharedManager valueForKey:@"diagnosticsByURI"] removeObjectForKey:uri];
        [[LSPManager.sharedManager valueForKey:@"diagnosticReportIdentifiers"] removeObjectForKey:uri];
        [DocumentWindowController enableSessionSave];
    });
    OAK_ASSERT([NSFileManager.defaultManager removeItemAtPath:directory error:nil]);
}

void test_editor_context_diagnostics_bounds_and_invalid_ranges ()
{
    NSString* message = [[@"x" stringByPaddingToLength:4095 withString:@"x" startingAtIndex:0] stringByAppendingString:@"😀suffix"];
    NSDictionary* item = @{ @"line": @0, @"character": @1, @"endLine": @0, @"endCharacter": @2,
                            @"message": message, @"severity": @2 };
    NSMutableArray* many = [NSMutableArray array];
    for(int i = 0; i < 100; ++i) [many addObject:item];
    NSDictionary* report = @{ @"diagnostics": many, @"reportId": @"bounded", @"status": @"reported", @"serverStatus": @"running", @"pendingChanges": @NO, @"freshness": @"unknown" };
    NSDictionary* result = EditorContextDiagnostics(report, @{}, @{}, @{ @"limit": @100 }, editor_context::now()+3);
    OAK_ASSERT([result[@"diagnostics"] count] > 0 && [result[@"diagnostics"] count] < 100);
    OAK_ASSERT([result[@"textTruncated"] boolValue] && [result[@"truncated"] boolValue]);
    OAK_ASSERT([result[@"nextOffset"] integerValue] == [result[@"diagnostics"] count]);
    OAK_ASSERT([result[@"diagnostics"][0][@"message"] length] == 4095); // No half of a surrogate pair.
    OAK_ASSERT([NSJSONSerialization dataWithJSONObject:result options:0 error:nil].length < editor_context::message_limit);
    NSMutableDictionary* invalid = [item mutableCopy];
    invalid[@"line"] = @(-1);
    NSMutableDictionary* invalidReport = [report mutableCopy];
    invalidReport[@"diagnostics"] = @[invalid];
    result = EditorContextDiagnostics(invalidReport, @{}, @{}, @{}, editor_context::now()+3);
    OAK_ASSERT(result[@"diagnostics"][0][@"range"] == NSNull.null);
    OAK_ASSERT([result[@"diagnostics"][0][@"invalidRange"] boolValue]);
    OAK_ASSERT([EditorContextDiagnostics(report, @{}, @{}, @{}, editor_context::now()-1)[@"code"] isEqual:@"timeout"]);
}

void test_editor_context_navigation_files_ranges_and_focus ()
{
    NSString* directory = [@"/tmp/tm-navigation-" stringByAppendingString:NSUUID.UUID.UUIDString];
    OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
    NSString* file = [directory stringByAppendingPathComponent:@"a 'quoted' file 😀.txt"];
    NSString* content = @"first\nA😀B\nlast\n";
    OAK_ASSERT([content writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    __block DocumentWindowController* window;
    __block DocumentWindowController* other;
    __block OakDocument* document;
    __block OakDocument* foreign;
    __block NSTextView* terminalFocus;
    __block NSDictionary* environment;
    NSUUID* session = NSUUID.UUID;
    dispatch_group_t loaded = dispatch_group_create();
    __block BOOL success = YES;
    dispatch_sync(dispatch_get_main_queue(), ^{
        [NSApplication sharedApplication];
        [DocumentWindowController disableSessionSave];
        window = [[DocumentWindowController alloc] init];
        other = [[DocumentWindowController alloc] init];
        document = [OakDocument documentWithString:@"A😀B\n\té z\nlast\n" fileType:@"text.plain" customName:@"unsaved navigation"];
        foreign = [OakDocument documentWithString:@"other window" fileType:@"text.plain" customName:@"foreign navigation"];
        for(OakDocument* doc in @[document, foreign]) {
            dispatch_group_enter(loaded);
            [doc loadModalForWindow:nil completionHandler:^(OakDocumentIOResult status, NSString*, oak::uuid_t const&){
                success = success && status == OakDocumentIOResultSuccess;
                dispatch_group_leave(loaded);
            }];
        }
    });
    OAK_ASSERT(dispatch_group_wait(loaded, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)) == 0 && success);
    dispatch_sync(dispatch_get_main_queue(), ^{
        [window setDocuments:@[document]]; [window setSelectedDocument:document];
        [other setDocuments:@[foreign]]; [other setSelectedDocument:foreign];
        terminalFocus = [[NSTextView alloc] initWithFrame:NSMakeRect(0,0,10,10)];
        [window.window.contentView addSubview:terminalFocus];
        [window.window makeFirstResponder:terminalFocus];
        __weak DocumentWindowController* owner = window;
        environment = [EditorContextService.sharedService environmentForSession:session provider:^EditorContextSnapshot*(NSString* method, NSDictionary* args){ return [owner editorContextForMethod:method arguments:args]; }];
    });
    NSDictionary* result = context_test_query(environment, @"navigate_editor", @{ @"documentId": document.identifier.UUIDString, @"line": @1, @"column": @2, @"endLine": @1, @"endColumn": @4 });
    OAK_ASSERT([result[@"status"] isEqual:@"navigated"] && ![result[@"opened"] boolValue]);
    OAK_ASSERT([result[@"range"][@"start"][@"offset"] integerValue] == 1 && [result[@"range"][@"end"][@"offset"] integerValue] == 3);
    OAK_ASSERT([context_test_query(environment)[@"selections"][0][@"text"] isEqual:@"😀"]);
    dispatch_sync(dispatch_get_main_queue(), ^{ OAK_ASSERT(window.window.firstResponder == terminalFocus); });
    result = context_test_query(environment, @"navigate_editor", @{ @"path": file, @"line": @2, @"column": @4, @"endLine": @2, @"endColumn": @5 });
    OAK_ASSERT([result[@"status"] isEqual:@"navigated"] && [result[@"opened"] boolValue]);
    NSString* openedId = result[@"document"][@"documentId"];
    NSDictionary* context = context_test_query(environment);
    OAK_ASSERT([context[@"document"][@"documentId"] isEqual:openedId]);
    OAK_ASSERT([context[@"selections"][0][@"text"] isEqual:@"B"]);
    result = context_test_query(environment, @"navigate_editor", @{ @"path": file });
    OAK_ASSERT(![result[@"opened"] boolValue] && result[@"range"] == NSNull.null);
    OAK_ASSERT([context_test_query(environment)[@"selections"][0][@"text"] isEqual:@"B"]);
    for(NSDictionary* args in @[
        @{ @"documentId": document.identifier.UUIDString, @"line": @99 },
        @{ @"documentId": document.identifier.UUIDString, @"line": @1, @"column": @3 },
        @{ @"documentId": document.identifier.UUIDString, @"revision": @"outdated", @"line": @1 },
        @{ @"documentId": foreign.identifier.UUIDString },
        @{ @"path": [directory stringByAppendingPathComponent:@"missing.txt"] }, @{ @"path": directory }
    ]) {
        OAK_ASSERT(context_test_query(environment, @"navigate_editor", args)[@"error"] != nil);
        OAK_ASSERT([context_test_query(environment)[@"document"][@"documentId"] isEqual:openedId]);
    }
    result = context_test_query(environment, @"navigate_editor", @{ @"documentId": document.identifier.UUIDString, @"line": @2, @"column": @2, @"endLine": @2, @"endColumn": @3, @"focus": @YES });
    OAK_ASSERT([result[@"status"] isEqual:@"navigated"] && [result[@"focused"] boolValue]);
    OAK_ASSERT([context_test_query(environment)[@"selections"][0][@"text"] isEqual:@"é"]);
    dispatch_sync(dispatch_get_main_queue(), ^{
        OAK_ASSERT(window.window.firstResponder == window.textView);
        OAK_ASSERT(window.documents.count == 2 && other.selectedDocument == foreign);
        OAK_ASSERT([document.content isEqual:@"A😀B\n\té z\nlast\n"]);
        [EditorContextService.sharedService revokeSession:session];
        [window close]; [other close];
        [document close]; [foreign close];
        [DocumentWindowController enableSessionSave];
    });
    OAK_ASSERT([[NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil] isEqual:content]);
    OAK_ASSERT([NSFileManager.defaultManager removeItemAtPath:directory error:nil]);
}

void test_editor_context_navigation_late_actions_and_session_transfer ()
{
    __block NSInteger effects = 0;
    dispatch_semaphore_t started = dispatch_semaphore_create(0);
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    NSUUID* session = NSUUID.UUID;
    __block NSDictionary* environment;
    dispatch_sync(dispatch_get_main_queue(), ^{
        environment = [EditorContextService.sharedService environmentForSession:session provider:^EditorContextSnapshot*(NSString*, NSDictionary*){
            return [EditorContextSnapshot action:^(double deadline, BOOL (^canCommit)(void), void (^completion)(NSDictionary*)){
                dispatch_semaphore_signal(started);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                    if(canCommit()) ++effects;
                    completion(canCommit() ? @{ @"status": @"navigated" } : editor_context::failure(@"Session changed", @"navigation_cancelled"));
                    dispatch_semaphore_signal(completed);
                });
            }];
        }];
    });
    __block NSDictionary* result;
    dispatch_group_t query = dispatch_group_create();
    dispatch_group_async(query, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ result = context_test_query(environment, @"navigate_editor", @{ @"path": @"/tmp/unused" }); });
    long startStatus = dispatch_semaphore_wait(started, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC));
    if(startStatus) NSLog(@"Navigation test did not start: %@", result);
    OAK_ASSERT(startStatus == 0);
    dispatch_sync(dispatch_get_main_queue(), ^{
        // Transfer keeps credentials but changes the registered owning provider.
        [EditorContextService.sharedService environmentForSession:session provider:^EditorContextSnapshot*(NSString*, NSDictionary*){ return [EditorContextSnapshot response:@{ @"window": @"destination" }]; }];
    });
    OAK_ASSERT(dispatch_group_wait(query, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    OAK_ASSERT([result[@"code"] isEqual:@"navigation_cancelled"] && effects == 0);
    OAK_ASSERT(dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    EditorContextSnapshot* late = [EditorContextSnapshot action:^(double deadline, BOOL (^canCommit)(void), void (^completion)(NSDictionary*)){
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if(canCommit()) ++effects;
            completion(@{});
            dispatch_semaphore_signal(completed);
        });
    }];
    OAK_ASSERT([[late renderBefore:editor_context::now()+0.03][@"code"] isEqual:@"timeout"]);
    OAK_ASSERT(dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    OAK_ASSERT(effects == 0);
    dispatch_sync(dispatch_get_main_queue(), ^{ [EditorContextService.sharedService revokeSession:session]; });
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
