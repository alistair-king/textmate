#import <Foundation/Foundation.h>
#import <EditorContextConnection.h>
#include <libproc.h>

static NSString* executable(NSString* path) {
    BOOL directory = NO;
    return [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] && !directory &&
        [NSFileManager.defaultManager isExecutableFileAtPath:path] ? path : nil;
}
static NSString* codex_executable() {
    NSDictionary* env = NSProcessInfo.processInfo.environment;
    if([env[@"TM_CODEX_COMMAND"] length]) return executable(env[@"TM_CODEX_COMMAND"]);
    for(NSString* directory in [env[@"PATH"] componentsSeparatedByString:@":"])
        if(NSString* path = executable([(directory.length ? directory : @".") stringByAppendingPathComponent:@"codex"])) return path;
    for(NSString* path in @[@"/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                            @"/opt/homebrew/bin/codex", @"/usr/local/bin/codex"])
        if(NSString* found = executable(path)) return found;
    return nil;
}
static NSString* toml_string(NSString* value) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:@[value] options:NSJSONWritingWithoutEscapingSlashes error:nil];
    NSString* encoded = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [encoded substringWithRange:NSMakeRange(1, encoded.length-2)];
}
int main(int argc, char const* argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        if(argc == 2 && !strcmp(argv[1], "--help")) {
            puts("Usage: tm-codex [Codex arguments...]\n       tm-codex --check\n\nStarts Codex with read-only context from this TextMate terminal.\nConnection configuration is temporary. Codex arguments and the current directory are preserved.\nSet TM_CODEX_COMMAND to an explicit Codex executable if it is not on PATH.");
            return 0;
        }
        if(argc == 2 && !strcmp(argv[1], "--check")) return editor_context::check_connection();
        NSDictionary* connection = editor_context::query(@"get_connection_status", @{});
        if(connection[@"error"]) {
            fprintf(stderr, "tm-codex (%s): %s\n", [connection[@"code"] UTF8String], [connection[@"error"] UTF8String]);
            return 1;
        }
        NSString* codex = codex_executable();
        if(!codex) {
            fprintf(stderr, "tm-codex: Codex CLI was not found. Install Codex CLI, add it to PATH, or set TM_CODEX_COMMAND to its executable. See https://learn.chatgpt.com/docs/cli\n");
            return 1;
        }
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if(proc_pidpath(getpid(), path, sizeof(path)) <= 0) return 1;
        NSString* helper = [[@(path) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"textmate-mcp"];
        if(!executable(helper)) { fprintf(stderr, "tm-codex: The bundled textmate-mcp helper is missing. Rebuild or reinstall TextMate.\n"); return 1; }
        NSString* configuration = [NSString stringWithFormat:@"mcp_servers.textmate={command=%@,args=[],env={},env_vars=[\"TM_CONTEXT_SOCKET\",\"TM_CONTEXT_SESSION\",\"TM_CONTEXT_TOKEN\"],enabled=true,required=true}", toml_string(helper)];
        // Global options must precede subcommands such as exec and resume.
        NSMutableArray<NSString*>* arguments = [NSMutableArray arrayWithObjects:codex, @"--no-daemon", @"-c", configuration, nil];
        for(int i = 1; i < argc; ++i) [arguments addObject:@(argv[i])];
        std::vector<char*> processArguments;
        for(NSString* argument in arguments) processArguments.push_back((char*)argument.UTF8String);
        processArguments.push_back(nullptr);
        execv(codex.fileSystemRepresentation, processArguments.data());
        fprintf(stderr, "tm-codex: Cannot start Codex: %s\n", strerror(errno));
        return 1;
    }
}
