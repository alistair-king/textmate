#import <Cocoa/Cocoa.h>
#import <EditorContextProtocol.h>
#import "../src/EditorContextService.h"
#import "../src/EditorContextBuffer.h"
#import "../src/EditorContextDiagnostics.h"
#import "../src/EditorLanguageIntelligence.h"
#import "../src/EditorContextChanges.h"
#import "../src/BufferEditProposal.h"
#import "../src/ProjectChangesWindowController.h"
#import <selection/selection.h>
#import <document/OakDocument Private.h>
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

void test_editor_context_follow_changes_and_bounded_history ()
{
    __block DocumentWindowController* window;
    __block OakDocument* first;
    __block OakDocument* second;
    dispatch_group_t loaded = dispatch_group_create();
    __block BOOL success = YES;
    dispatch_sync(dispatch_get_main_queue(), ^{
        [NSApplication sharedApplication];
        [DocumentWindowController disableSessionSave];
        window = [[DocumentWindowController alloc] init];
        first = [OakDocument documentWithString:@"A😀B\n" fileType:@"text.plain" customName:@"first follow"];
        second = [OakDocument documentWithString:@"second" fileType:@"text.plain" customName:@"second follow"];
        for(OakDocument* document in @[first, second]) {
            dispatch_group_enter(loaded);
            [document loadModalForWindow:nil completionHandler:^(OakDocumentIOResult status, NSString*, oak::uuid_t const&){
                success = success && status == OakDocumentIOResultSuccess;
                dispatch_group_leave(loaded);
            }];
        }
    });
    OAK_ASSERT(dispatch_group_wait(loaded, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)) == 0 && success);
    dispatch_sync(dispatch_get_main_queue(), ^{
        [window setDocuments:@[first, second]]; [window setSelectedDocument:first];
        NSDictionary* initial = [window testEditorContextForMethod:@"get_editor_changes" arguments:@{}];
        OAK_ASSERT([initial[@"reset"] boolValue] && [initial[@"changed"] boolValue]);
        OAK_ASSERT([initial[@"context"][@"document"][@"documentId"] isEqual:first.identifier.UUIDString]);
        NSString* cursor = initial[@"cursor"];
        OAK_ASSERT([cursor isEqual:initial[@"context"][@"changeCursor"]]);
        NSDictionary* unchanged = [window testEditorContextForMethod:@"get_editor_changes" arguments:@{ @"cursor": cursor }];
        OAK_ASSERT(![unchanged[@"changed"] boolValue] && unchanged[@"context"] == nil);
        OAK_ASSERT([[window testEditorContextForMethod:@"get_editor_change_token" arguments:@{}][@"cursor"] isEqual:cursor]);
        window.textView.selectionString = @"1:2-1:6";
        NSDictionary* selection = [window testEditorContextForMethod:@"get_editor_changes" arguments:@{ @"cursor": cursor }];
        OAK_ASSERT([selection[@"changed"] boolValue] && ![selection[@"reset"] boolValue]);
        OAK_ASSERT([[selection[@"events"] valueForKey:@"type"] containsObject:@"selection"]);
        OAK_ASSERT([selection[@"context"][@"selections"][0][@"text"] isEqual:@"😀"]);
        cursor = selection[@"cursor"];
        first.content = @"edited without saving";
        NSDictionary* content = [window testEditorContextForMethod:@"get_editor_changes" arguments:@{ @"cursor": cursor }];
        OAK_ASSERT([[content[@"events"] valueForKey:@"type"] containsObject:@"content"]);
        OAK_ASSERT(![content[@"context"][@"document"][@"revision"] isEqual:initial[@"context"][@"document"][@"revision"]]);
        cursor = content[@"cursor"];
        [window setSelectedDocument:second];
        NSDictionary* switched = [window testEditorContextForMethod:@"get_editor_changes" arguments:@{ @"cursor": cursor }];
        OAK_ASSERT([[switched[@"events"] valueForKey:@"type"] containsObject:@"document"]);
        OAK_ASSERT([switched[@"context"][@"document"][@"documentId"] isEqual:second.identifier.UUIDString]);
        cursor = switched[@"cursor"];
        first.content = @"inactive document edit";
        NSDictionary* inactive = [window testEditorContextForMethod:@"get_editor_changes" arguments:@{ @"cursor": cursor }];
        OAK_ASSERT([[inactive[@"events"] valueForKey:@"documentId"] containsObject:first.identifier.UUIDString]);
        OAK_ASSERT([inactive[@"context"][@"document"][@"documentId"] isEqual:second.identifier.UUIDString]);
        cursor = inactive[@"cursor"];
        [window setDocuments:@[second]];
        NSDictionary* tabs = [window testEditorContextForMethod:@"get_editor_changes" arguments:@{ @"cursor": cursor }];
        OAK_ASSERT([[tabs[@"events"] valueForKey:@"type"] containsObject:@"documents"]);
        NSDictionary* foreign = [window testEditorContextForMethod:@"get_editor_changes" arguments:@{ @"cursor": @"another-window/0" }];
        OAK_ASSERT([foreign[@"reset"] boolValue] && foreign[@"context"] != nil);
        EditorContextChanges* journal = [EditorContextChanges new];
        NSString* old = journal.cursor;
        for(int i = 0; i < 200; ++i) [journal record:@"selection" documentId:second.identifier.UUIDString];
        OAK_ASSERT([[journal changesAfter:old][@"reset"] boolValue]);
        NSString* recent = journal.cursor;
        [journal record:@"content" documentId:second.identifier.UUIDString];
        NSDictionary* delta = [journal changesAfter:recent];
        OAK_ASSERT(![delta[@"reset"] boolValue] && [delta[@"events"] count] == 1);
        OAK_ASSERT(![[journal changesAfter:journal.cursor][@"changed"] boolValue]);
        [window setSelectedDocument:nil]; [window setDocuments:@[]];
        [first close]; [second close]; [window close];
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
    OAK_MASSERT([timeout.description UTF8String] ?: "No timeout response was received", [timeout[@"code"] isEqual:@"timeout"]);
    dispatch_sync(dispatch_get_main_queue(), ^{ [document close]; });
}

void test_editor_context_stray_continuation_byte_offsets ()
{
    __block OakDocument* document;
    __block EditorContextBuffer* snapshot;
    __block BOOL loaded = NO;
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    dispatch_sync(dispatch_get_main_queue(), ^{
        document = [OakDocument documentWithString:@"AB" fileType:@"text.plain" customName:@"stray continuation byte"];
        [document loadModalForWindow:nil completionHandler:^(OakDocumentIOResult status, NSString*, oak::uuid_t const&){
            loaded = status == OakDocumentIOResultSuccess;
            dispatch_semaphore_signal(ready);
        }];
    });
    OAK_ASSERT(dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
    OAK_ASSERT(loaded);
    dispatch_sync(dispatch_get_main_queue(), ^{
        // The open path rejects undecodable files, so the raw buffer is edited directly.
        document.buffer.insert(1, "\x80\x80", 2);
        OAK_ASSERT(document.buffer.size() == 4);
        snapshot = [EditorContextBuffer bufferForDocument:document revision:@"stray continuation byte"];
    });
    auto read = ^NSDictionary*(NSUInteger offset, NSUInteger length){
        return [snapshot responseForMethod:@"read_document" arguments:@{ @"offset": @(offset), @"length": @(length) }
            base:@{} document:@{} ranges:ng::ranges_t() caret:0 deadline:editor_context::now()+3];
    };
    NSUInteger total = [read(0, 4)[@"totalLength"] unsignedIntegerValue];
    OAK_ASSERT(total == 2);
    // Every reported offset must map back to the byte it came from.
    for(NSUInteger offset = 0; offset <= total; ++offset)
        OAK_ASSERT_EQ([read(offset, 0)[@"nextOffset"] unsignedIntegerValue], offset);
    // Reading the buffer in order must reach the end instead of stalling.
    NSUInteger offset = 0;
    for(size_t i = 0; i < 8 && offset < total; ++i) {
        NSUInteger next = [read(offset, 1)[@"nextOffset"] unsignedIntegerValue];
        OAK_ASSERT(next > offset);
        offset = next;
    }
    OAK_ASSERT(offset == total);
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
        firstPanel.terminalDirectoryProvider = ^{ return NSTemporaryDirectory(); };
        secondPanel.terminalDirectoryProvider = ^{ return NSTemporaryDirectory(); };
        [firstPanel startTerminal];
        [secondPanel startTerminal];
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
    NSDictionary* transferredChanges = context_test_query(firstEnvironment, @"get_editor_changes", @{ @"cursor": firstResult[@"changeCursor"] });
    OAK_ASSERT([transferredChanges[@"reset"] boolValue]);
    OAK_ASSERT([transferredChanges[@"context"][@"document"][@"documentId"] isEqual:secondDocument.identifier.UUIDString]);
    dispatch_sync(dispatch_get_main_queue(), ^{
        [second close];
        [firstDocument close]; [secondDocument close];
        [DocumentWindowController enableSessionSave];
    });
    OAK_ASSERT([context_test_query(firstEnvironment)[@"code"] isEqual:@"session_unavailable"]);
    OAK_ASSERT([context_test_query(secondEnvironment)[@"code"] isEqual:@"session_unavailable"]);
}

void test_project_changes_unsaved_snapshot_and_navigation ()
{
    NSString* directory = [@"/tmp/textmate-changes-buffer-" stringByAppendingString:NSUUID.UUID.UUIDString];
    OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
    NSString* path = [directory stringByAppendingPathComponent:@"buffer.txt"];
    OAK_ASSERT([@"saved text\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    NSTask* git = [[NSTask alloc] init];
    git.executableURL = [NSURL fileURLWithPath:@"/usr/bin/git"];
    git.arguments = @[@"-C", directory, @"init", @"--quiet"];
    OAK_ASSERT([git launchAndReturnError:nil]); [git waitUntilExit];
    OAK_ASSERT(git.terminationStatus == 0);
    __block OakDocument* document;
    __block ProjectChangesBuffer* buffer;
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    dispatch_sync(dispatch_get_main_queue(), ^{
        [NSApplication sharedApplication];
        document = [OakDocument documentWithPath:path];
        document.fileType = @"text.plain";
        [document loadModalForWindow:nil completionHandler:^(OakDocumentIOResult status, NSString*, oak::uuid_t const&){
            OAK_ASSERT(status == OakDocumentIOResultSuccess); dispatch_semaphore_signal(ready);
        }];
    });
    OAK_ASSERT(dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)) == 0);
    dispatch_sync(dispatch_get_main_queue(), ^{
        document.content = @"unsaved 😀\n";
        buffer = [ProjectChangesBuffer captureDocument:document];
        document.content = @"later typing\n";
    });
    NSDictionary* buffers = @{ path: buffer };
    NSDictionary* snapshot = ProjectChangesSnapshot(directory, buffers);
    OAK_ASSERT(!snapshot[@"error"] && [snapshot[@"files"] count] == 1);
    NSDictionary* file = snapshot[@"files"][0];
    OAK_ASSERT([file[@"unsaved"] boolValue]);
    NSDictionary* diff = ProjectChangesDiff(snapshot, file, buffers);
    OAK_ASSERT([diff[@"text"] containsString:@"+unsaved 😀"]);
    OAK_ASSERT(![diff[@"text"] containsString:@"later typing"]);
    OAK_ASSERT([[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] isEqual:@"saved text\n"]);
    __block ProjectChangesWindowController* review;
    __block BOOL opened = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        review = [[ProjectChangesWindowController alloc] initWithDirectory:directory buffers:^NSDictionary*{ return buffers; } openFile:^(NSString* openedPath, NSUInteger line){
            opened = [openedPath.lastPathComponent isEqual:@"buffer.txt"] && line == 1;
        }];
        [review showWindow:nil];
    });
    __block BOOL loaded = NO;
    for(int i = 0; i < 300; ++i) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            loaded = [[review valueForKey:@"files"] count] == 1 && ![[review valueForKey:@"loadingDiff"] boolValue] && [review valueForKey:@"displayedDiff"] != nil;
        });
        if(loaded) break;
        usleep(10000);
    }
    OAK_ASSERT(loaded);
    dispatch_sync(dispatch_get_main_queue(), ^{
        OAK_ASSERT([[review valueForKey:@"diffView"] string] != nil);
        OAK_ASSERT([[[review valueForKey:@"diffView"] string] containsString:@"+unsaved 😀"]);
        NSButton* open = [review valueForKey:@"openButton"];
        OAK_ASSERT(open.enabled);
        [open performClick:nil];
        OAK_ASSERT(opened);
        [review close]; [document close];
    });
    OAK_ASSERT([NSFileManager.defaultManager removeItemAtPath:directory error:nil]);
}


void test_editor_language_normalization_bounds_and_server_data ()
{
    NSDictionary* range = @{ @"start": @{ @"line": @0, @"character": @3 }, @"end": @{ @"line": @0, @"character": @4 } };
    NSDictionary* metadata = @{ @"path": @"/tmp/language 😀.txt" };
    NSDictionary* link = @{ @"targetUri": @"file:///tmp/other.txt", @"targetSelectionRange": range };
    NSDictionary* result = EditorLanguageNormalize(@"get_definition", @[link, @{}, @7], metadata, editor_context::now()+3);
    OAK_ASSERT([result[@"items"] count] == 1 && [result[@"invalidCount"] integerValue] == 2);
    OAK_ASSERT([result[@"items"][0][@"range"][@"start"][@"column"] integerValue] == 4);
    OAK_ASSERT([result[@"items"][0][@"location"] isEqual:@"/tmp/other.txt:1"]);
    OAK_ASSERT(([EditorLanguageNormalize(@"get_definition", NSNull.null, metadata, editor_context::now()+3)[@"items"] count] == 0));
    OAK_ASSERT((EditorLanguageNormalize(@"find_references", @{}, metadata, editor_context::now()+3)[@"error"] != nil));
    NSDictionary* unresolved = @{ @"name": @"Unresolved", @"kind": @12, @"location": @{ @"uri": @"file:///tmp/other.txt" } };
    result = EditorLanguageNormalize(@"search_workspace_symbols", @[unresolved], metadata, editor_context::now()+3);
    OAK_ASSERT([result[@"items"][0][@"unresolved"] boolValue] && result[@"items"][0][@"range"] == NSNull.null);
    NSMutableArray* many = [NSMutableArray array];
    for(int i = 0; i < 1100; ++i) [many addObject:link];
    result = EditorLanguageNormalize(@"get_definition", many, metadata, editor_context::now()+3);
    OAK_ASSERT([result[@"items"] count] <= 1000 && [result[@"resultsTruncated"] boolValue]);
    NSString* large = [[@"a" stringByPaddingToLength:8191 withString:@"a" startingAtIndex:0] stringByAppendingString:@"😀"];
    result = EditorLanguageNormalize(@"get_hover", @{ @"contents": large }, metadata, editor_context::now()+3);
    OAK_ASSERT([result[@"hover"][@"textTruncated"] boolValue]);
    OAK_ASSERT([result[@"hover"][@"text"] length] == 8191);
    OAK_ASSERT((EditorLanguageNormalize(@"get_definition", @[], metadata, editor_context::now()-1)[@"error"] != nil));
}

void test_editor_language_queries_real_server_and_session_boundary ()
{
    NSString* path = [@"/tmp/textmate-language-" stringByAppendingString:NSUUID.UUID.UUIDString];
    OAK_ASSERT([@"A😀B\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    __block OakDocument* document;
    __block DocumentWindowController* window;
    __block LSPClient* client;
    __block NSDictionary* environment;
    NSUUID* session = NSUUID.UUID;
    dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
    dispatch_sync(dispatch_get_main_queue(), ^{
        [NSApplication sharedApplication];
        [DocumentWindowController disableSessionSave];
        window = [[DocumentWindowController alloc] init];
        document = [OakDocument documentWithPath:path]; document.fileType = @"text.plain";
        [document loadModalForWindow:nil completionHandler:^(OakDocumentIOResult status, NSString*, oak::uuid_t const&){
            OAK_ASSERT(status == OakDocumentIOResultSuccess); dispatch_semaphore_signal(loaded);
        }];
        NSString* fixture = [@(__FILE__).stringByDeletingLastPathComponent stringByAppendingPathComponent:@"language_server.py"];
        client = [[LSPClient alloc] initWithCommand:@"/usr/bin/python3" arguments:@[fixture] workingDirectory:@"/tmp" initOptions:nil];
    });
    OAK_ASSERT(dispatch_semaphore_wait(loaded, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)) == 0);
    __block BOOL initialized = NO;
    for(int i = 0; i < 500; ++i) {
        dispatch_sync(dispatch_get_main_queue(), ^{ initialized = client.initialized; });
        if(initialized) break;
        usleep(10000);
    }
    OAK_ASSERT(initialized);
    dispatch_sync(dispatch_get_main_queue(), ^{
        [window setDocuments:@[document]]; [window setSelectedDocument:document];
        [client openDocument:document languageId:@"plaintext"];
        LSPManager* manager = LSPManager.sharedManager;
        [manager valueForKey:@"documentClients"][document.identifier] = client;
        [[manager valueForKey:@"openDocuments"] addObject:document.identifier];
        environment = [EditorContextService.sharedService environmentForSession:session provider:^EditorContextSnapshot*(NSString* method, NSDictionary* args){ return [window editorContextForMethod:method arguments:args]; }];
        document.content = @"A😀B unsaved\n";
        window.textView.selectionString = @"1:6";
    });
    NSDictionary* definition = context_test_query(environment, @"get_definition");
    OAK_ASSERT(!definition[@"error"] && [definition[@"items"] count] == 1);
    OAK_ASSERT([definition[@"items"][0][@"range"][@"start"][@"column"] integerValue] == 4);
    OAK_ASSERT([context_test_query(environment, @"get_definition", @{ @"line": @1, @"column": @3 })[@"code"] isEqual:@"invalid_position"]);
    OAK_ASSERT([context_test_query(environment, @"get_definition", @{ @"documentId": NSUUID.UUID.UUIDString })[@"code"] isEqual:@"document_unavailable"]);
    NSDictionary* hover = context_test_query(environment, @"get_hover");
    NSDictionary* echoed = editor_context::parse([hover[@"hover"][@"text"] dataUsingEncoding:NSUTF8StringEncoding]);
    OAK_ASSERT([echoed[@"text"] isEqual:@"A😀B unsaved\n"]);
    OAK_ASSERT([echoed[@"position"][@"character"] integerValue] == 3); // byte 5 → UTF-16 3
    NSDictionary* references = context_test_query(environment, @"find_references", @{ @"limit": @100 });
    OAK_ASSERT(!references[@"error"] && [references[@"items"] count] == 100 && [references[@"availableCount"] integerValue] == 205);
    NSDictionary* page = context_test_query(environment, @"find_references", @{ @"resultId": references[@"resultId"], @"offset": @100, @"limit": @100 });
    OAK_ASSERT([page[@"items"] count] == 100 && [page[@"nextOffset"] integerValue] == 200);
    page = context_test_query(environment, @"find_references", @{ @"resultId": references[@"resultId"], @"offset": @200 });
    OAK_ASSERT([page[@"items"] count] == 5 && page[@"nextOffset"] == NSNull.null);
    NSDictionary* symbols = context_test_query(environment, @"get_document_symbols");
    OAK_ASSERT([symbols[@"items"] count] == 2 && [symbols[@"items"][1][@"container"] isEqual:@"Outer"]);
    NSDictionary* workspace = context_test_query(environment, @"search_workspace_symbols", @{ @"query": @"Example" });
    OAK_ASSERT([workspace[@"items"][0][@"location"] isEqual:@"/tmp/workspace-symbol.txt:5"]);
    OAK_ASSERT([context_test_query(environment, @"search_workspace_symbols", @{ @"query": @"error" })[@"code"] isEqual:@"language_request_failed"]);
    NSDictionary* timeout = context_test_query(environment, @"search_workspace_symbols", @{ @"query": @"timeout" });
    OAK_MASSERT([timeout.description UTF8String] ?: "No timeout response was received", [timeout[@"code"] isEqual:@"timeout"]);
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ document.content = @"changed while querying"; });
    });
    OAK_ASSERT([context_test_query(environment, @"search_workspace_symbols", @{ @"query": @"slow" })[@"code"] isEqual:@"document_changed"]);
    OAK_ASSERT([context_test_query(environment, @"find_references", @{ @"resultId": references[@"resultId"], @"offset": @100 })[@"code"] isEqual:@"result_expired"]);
    dispatch_sync(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [EditorContextService.sharedService revokeSession:session]; });
    });
    OAK_ASSERT([context_test_query(environment, @"search_workspace_symbols", @{ @"query": @"slow" })[@"error"] isKindOfClass:NSString.class]);
    dispatch_sync(dispatch_get_main_queue(), ^{
        [LSPManager.sharedManager documentWillClose:document];
        [client shutdown];
        [window setSelectedDocument:nil]; [window setDocuments:@[]]; [document close]; [window close];
        [DocumentWindowController enableSessionSave];
    });
    OAK_ASSERT([NSFileManager.defaultManager removeItemAtPath:path error:nil]);
}


void test_document_edit_plan_unicode_insert_delete_and_undo ()
{
    __block DocumentWindowController* window;
    __block OakDocument* document;
    __block NSDictionary* metadata;
    __block EditorContextBuffer* buffer;
    dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
    dispatch_sync(dispatch_get_main_queue(), ^{
        [NSApplication sharedApplication]; [DocumentWindowController disableSessionSave];
        window = [[DocumentWindowController alloc] init];
        document = [OakDocument documentWithString:@"A😀B\nkeep\n" fileType:@"text.plain" customName:@"live edit buffer"];
        [document loadModalForWindow:nil completionHandler:^(OakDocumentIOResult status, NSString*, oak::uuid_t const&){
            OAK_ASSERT(status == OakDocumentIOResultSuccess); dispatch_semaphore_signal(loaded);
        }];
    });
    OAK_ASSERT(dispatch_semaphore_wait(loaded, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)) == 0);
    dispatch_sync(dispatch_get_main_queue(), ^{
        [window setDocuments:@[document]]; [window setSelectedDocument:document];
        metadata = [window testEditorContextForMethod:@"get_editor_context" arguments:@{}][@"document"];
        buffer = [EditorContextBuffer bufferForDocument:document revision:metadata[@"revision"]];
    });
    NSDictionary* (^arguments)(NSArray*) = ^NSDictionary*(NSArray* edits){ return @{ @"documentId": metadata[@"documentId"], @"revision": metadata[@"revision"], @"summary": @"Edit the live buffer", @"edits": edits }; };
    NSDictionary* plan = [buffer editPlanForArguments:arguments(@[
        @{ @"offset": @5, @"length": @4, @"text": @"stay" },
        @{ @"offset": @1, @"length": @2, @"text": @"🛠️" },
        @{ @"offset": @10, @"length": @0, @"text": @"tail\n" },
        @{ @"offset": @3, @"length": @1, @"text": @"" }]) document:metadata deadline:editor_context::now()+3];
    OAK_ASSERT(plan[@"error"] == nil);
    NSString* error = nil;
    BufferEditProposal* proposal = [[BufferEditProposal alloc] initWithEditPlan:plan summary:@"Update the buffer" error:&error];
    OAK_ASSERT(proposal != nil && error == nil);
    dispatch_sync(dispatch_get_main_queue(), ^{
        OAK_ASSERT([document.content isEqual:@"A😀B\nkeep\n"]);
        OAK_ASSERT([proposal applyToDocument:document]);
        OAK_ASSERT([document.content isEqual:@"A🛠️\nstay\ntail\n"]);
        OAK_ASSERT(![proposal applyToDocument:document]);
        [document undo];
        OAK_ASSERT([document.content isEqual:@"A😀B\nkeep\n"]);
    });
    NSArray* invalidRanges = @[
        @[@{ @"offset": @2, @"length": @0, @"text": @"x" }],
        @[@{ @"offset": @1, @"length": @1, @"text": @"x" }],
        @[@{ @"offset": @11, @"length": @0, @"text": @"x" }],
        @[@{ @"offset": @10, @"length": @1, @"text": @"x" }],
        @[@{ @"offset": @0, @"length": @3, @"text": @"x" }, @{ @"offset": @1, @"length": @2, @"text": @"y" }],
        @[@{ @"offset": @0, @"length": @0, @"text": @"x" }, @{ @"offset": @0, @"length": @0, @"text": @"y" }]
    ];
    for(NSArray* edits in invalidRanges) {
        NSDictionary* invalid = [buffer editPlanForArguments:arguments(edits) document:metadata deadline:editor_context::now()+3];
        OAK_ASSERT(invalid[@"error"] != nil);
    }
    plan = [buffer editPlanForArguments:arguments(@[@{ @"offset": @0, @"length": @0, @"text": @"" }]) document:metadata deadline:editor_context::now()+3];
    OAK_ASSERT([[BufferEditProposal alloc] initWithEditPlan:plan summary:@"No change" error:&error] == nil);
    dispatch_sync(dispatch_get_main_queue(), ^{
        document.content = @"";
        metadata = [window testEditorContextForMethod:@"get_editor_context" arguments:@{}][@"document"];
        buffer = [EditorContextBuffer bufferForDocument:document revision:metadata[@"revision"]];
    });
    plan = [buffer editPlanForArguments:arguments(@[@{ @"offset": @0, @"length": @0, @"text": @"new 😀" }]) document:metadata deadline:editor_context::now()+3];
    proposal = [[BufferEditProposal alloc] initWithEditPlan:plan summary:@"Start an empty document" error:&error];
    OAK_ASSERT(proposal != nil);
    dispatch_sync(dispatch_get_main_queue(), ^{
        OAK_ASSERT([proposal applyToDocument:document]);
        OAK_ASSERT([document.content isEqual:@"new 😀"]);
        [document undo]; OAK_ASSERT([document.content isEqual:@""]);
    });
    // A later edit invalidates even an insertion into the empty buffer.
    proposal = [[BufferEditProposal alloc] initWithEditPlan:plan summary:@"Stale change" error:&error];
    dispatch_sync(dispatch_get_main_queue(), ^{
        document.content = @"user typing";
        OAK_ASSERT(![proposal applyToDocument:document] && [proposal.status isEqual:@"stale"]);
        [window setSelectedDocument:nil]; [window setDocuments:@[]]; [document close]; [window close];
        [DocumentWindowController enableSessionSave];
    });
}

static void document_edit_test_end_review(DocumentWindowController* window, NSModalResponse response)
{
    dispatch_sync(dispatch_get_main_queue(), ^{
        EditReviewWindowController* review = [window valueForKey:@"editReviewController"];
        OAK_ASSERT(review.window.isVisible && window.window.attachedSheet == nil);
        if(response == NSAlertFirstButtonReturn) [review apply:nil];
        else [review.window performClose:nil]; // Closing the window discards, too.
    });
    // Wait for proposal review completion before inspecting its effects.
    for(int i = 0; i < 100; ++i) {
        __block BOOL closed;
        dispatch_sync(dispatch_get_main_queue(), ^{
            closed = [window valueForKey:@"editReviewController"] == nil;
            for(BufferEditProposal* proposal in [[window valueForKey:@"editProposals"] allValues])
                if([proposal.status isEqual:@"pending_review"]) closed = NO;
        });
        if(closed) break;
        usleep(10000);
    }
}

void test_document_edit_proposals_live_review_window_scope_and_disk ()
{
    NSString* path = [@"/tmp/textmate-buffer-proposal-" stringByAppendingString:NSUUID.UUID.UUIDString];
    OAK_ASSERT([@"one\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    __block DocumentWindowController* window;
    __block OakDocument* document;
    __block OakDocument* untitled;
    __block NSDictionary* environment;
    NSUUID* session = NSUUID.UUID;
    dispatch_group_t loaded = dispatch_group_create();
    dispatch_sync(dispatch_get_main_queue(), ^{
        [NSApplication sharedApplication]; [DocumentWindowController disableSessionSave];
        window = [[DocumentWindowController alloc] init];
        document = [OakDocument documentWithPath:path]; document.fileType = @"text.plain";
        untitled = [OakDocument documentWithString:@"other" fileType:@"text.plain" customName:@"untitled target"];
        for(OakDocument* target in @[document, untitled]) {
            dispatch_group_enter(loaded);
            [target loadModalForWindow:nil completionHandler:^(OakDocumentIOResult status, NSString*, oak::uuid_t const&){
                OAK_ASSERT(status == OakDocumentIOResultSuccess); dispatch_group_leave(loaded);
            }];
        }
    });
    OAK_ASSERT(dispatch_group_wait(loaded, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)) == 0);
    dispatch_sync(dispatch_get_main_queue(), ^{
        [window setDocuments:@[document, untitled]]; [window setSelectedDocument:untitled]; [window showWindow:nil];
        environment = [EditorContextService.sharedService environmentForSession:session provider:^EditorContextSnapshot*(NSString* method, NSDictionary* args){ return [window editorContextForMethod:method arguments:args]; }];
    });
    NSDictionary* source = context_test_query(environment, @"read_document", @{ @"documentId": document.identifier.UUIDString });
    NSDictionary* args = @{ @"documentId": document.identifier.UUIDString, @"revision": source[@"document"][@"revision"], @"summary": @"Update the inactive buffer",
        @"edits": @[@{ @"offset": @0, @"length": @3, @"text": @"two" }, @{ @"offset": @4, @"length": @0, @"text": @"tail\n" }] };
    NSMutableDictionary* invalid = [args mutableCopy]; invalid[@"documentId"] = NSUUID.UUID.UUIDString;
    OAK_ASSERT([context_test_query(environment, @"propose_document_edits", invalid)[@"code"] isEqual:@"document_unavailable"]);
    invalid = [args mutableCopy]; invalid[@"revision"] = @"old revision";
    OAK_ASSERT([context_test_query(environment, @"propose_document_edits", invalid)[@"code"] isEqual:@"document_changed"]);
    NSDictionary* proposal = context_test_query(environment, @"propose_document_edits", args);
    OAK_ASSERT([proposal[@"status"] isEqual:@"pending_review"] && ![proposal[@"applied"] boolValue]);
    NSDictionary* statusArgs = @{ @"proposalId": proposal[@"proposalId"] };
    OAK_ASSERT([context_test_query(environment, @"get_edit_proposal_status", statusArgs)[@"status"] isEqual:@"pending_review"]);
    OAK_ASSERT([context_test_query(environment, @"propose_document_edits", args)[@"code"] isEqual:@"review_unavailable"]);
    dispatch_sync(dispatch_get_main_queue(), ^{
        OAK_ASSERT([document.content isEqual:@"one\n"] && [untitled.content isEqual:@"other"]);
        OAK_ASSERT(window.selectedDocument == untitled);
        DocumentWindowController* foreign = [[DocumentWindowController alloc] init];
        OAK_ASSERT([foreign testEditorContextForMethod:@"get_edit_proposal_status" arguments:statusArgs][@"error"] != nil);
        [foreign close];
    });
    document_edit_test_end_review(window, NSAlertFirstButtonReturn);
    NSDictionary* status = context_test_query(environment, @"get_edit_proposal_status", statusArgs);
    OAK_ASSERT([status[@"status"] isEqual:@"applied"]);
    OAK_ASSERT(![status[@"document"][@"revision"] isEqual:source[@"document"][@"revision"]]);
    dispatch_sync(dispatch_get_main_queue(), ^{
        OAK_ASSERT([document.content isEqual:@"two\ntail\n"]);
        OAK_ASSERT(document.isDocumentEdited && window.selectedDocument == untitled);
        OAK_ASSERT([[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] isEqual:@"one\n"]);
        [document undo]; OAK_ASSERT([document.content isEqual:@"one\n"]);
    });
    OAK_ASSERT([context_test_query(environment, @"propose_document_edits", args)[@"code"] isEqual:@"document_changed"]);
    source = context_test_query(environment, @"read_document", @{ @"documentId": untitled.identifier.UUIDString });
    args = @{ @"documentId": untitled.identifier.UUIDString, @"revision": source[@"document"][@"revision"], @"summary": @"Change untitled text",
        @"edits": @[@{ @"offset": @0, @"length": @5, @"text": @"updated" }] };
    proposal = context_test_query(environment, @"propose_document_edits", args);
    OAK_ASSERT([proposal[@"status"] isEqual:@"pending_review"]);
    statusArgs = @{ @"proposalId": proposal[@"proposalId"] };
    document_edit_test_end_review(window, NSAlertSecondButtonReturn);
    OAK_ASSERT([context_test_query(environment, @"get_edit_proposal_status", statusArgs)[@"status"] isEqual:@"discarded"]);
    dispatch_sync(dispatch_get_main_queue(), ^{ OAK_ASSERT([untitled.content isEqual:@"other"]); });
    // Editing while the sheet is open must prevent application.
    proposal = context_test_query(environment, @"propose_document_edits", args);
    OAK_ASSERT([proposal[@"status"] isEqual:@"pending_review"]);
    statusArgs = @{ @"proposalId": proposal[@"proposalId"] };
    dispatch_sync(dispatch_get_main_queue(), ^{
        untitled.content = @"new user typing";
        [(EditReviewWindowController*)[window valueForKey:@"editReviewController"] apply:nil];
    });
    __block BOOL rejected = NO;
    for(int i = 0; i < 200; ++i) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            NSWindow* sheet = window.window.attachedSheet;
            if(sheet && [sheet.title isEqual:@"Edits Could Not Be Applied"]) rejected = YES;
            // NSAlert sheets do not consistently expose their message as title.
            BufferEditProposal* pending = [window valueForKey:@"editProposals"][proposal[@"proposalId"]];
            if([pending.status isEqual:@"stale"]) { rejected = YES; if(sheet) [window.window endSheet:sheet returnCode:NSAlertFirstButtonReturn]; }
        });
        if(rejected) break;
        usleep(10000);
    }
    OAK_ASSERT(rejected);
    OAK_ASSERT([context_test_query(environment, @"get_edit_proposal_status", statusArgs)[@"status"] isEqual:@"stale"]);
    dispatch_sync(dispatch_get_main_queue(), ^{
        OAK_ASSERT([untitled.content isEqual:@"new user typing"]);
        [EditorContextService.sharedService revokeSession:session];
        [window setSelectedDocument:nil]; [window setDocuments:@[]];
        [document close]; [untitled close]; [window close]; [DocumentWindowController enableSessionSave];
    });
    OAK_ASSERT([NSFileManager.defaultManager removeItemAtPath:path error:nil]);
}
