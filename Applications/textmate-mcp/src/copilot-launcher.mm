#import <Foundation/Foundation.h>
#import <EditorContextConnection.h>
#import "LauncherUtilities.h"

int main(int argc, char const* argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        if(argc == 2 && !strcmp(argv[1], "--help")) {
            puts("Usage: tm-copilot [Copilot CLI arguments...]\n       tm-copilot --check\n\nStarts GitHub Copilot CLI with editor context and navigation from this TextMate terminal.\nConnection configuration is temporary. Arguments and the current directory are preserved.\nSet TM_COPILOT_COMMAND to an explicit Copilot executable if it is not on PATH.");
            return 0;
        }
        if(argc == 2 && !strcmp(argv[1], "--check")) return editor_context::check_connection();
        NSDictionary* connection = editor_context::query(@"get_connection_status", @{});
        if(connection[@"error"]) {
            fprintf(stderr, "tm-copilot (%s): %s\n", [connection[@"code"] UTF8String], [connection[@"error"] UTF8String]);
            return 1;
        }
        NSString* copilot = launcher::find(@"copilot", @"TM_COPILOT_COMMAND", @[
            [NSHomeDirectory() stringByAppendingPathComponent:@".local/bin/copilot"],
            @"/opt/homebrew/bin/copilot", @"/usr/local/bin/copilot"]);
        if(!copilot) {
            fprintf(stderr, "tm-copilot: GitHub Copilot CLI was not found. Install Copilot CLI, add it to PATH, or set TM_COPILOT_COMMAND to its executable. See https://docs.github.com/copilot/how-tos/copilot-cli\n");
            return 1;
        }
        NSString* helper = launcher::helper();
        if(!helper) { fprintf(stderr, "tm-copilot: The bundled textmate-mcp helper is missing. Rebuild or reinstall TextMate.\n"); return 1; }
        // Copilot expands ${VAR} in env values, so credentials never appear in argv or a config file.
        NSDictionary* configuration = @{ @"mcpServers": @{ @"textmate": @{
            @"type": @"stdio", @"command": helper, @"args": @[], @"tools": @[@"*"], @"env": @{
                @"TM_CONTEXT_SOCKET": @"${TM_CONTEXT_SOCKET}",
                @"TM_CONTEXT_SESSION": @"${TM_CONTEXT_SESSION}",
                @"TM_CONTEXT_TOKEN": @"${TM_CONTEXT_TOKEN}" } } } };
        NSData* data = [NSJSONSerialization dataWithJSONObject:configuration options:NSJSONWritingWithoutEscapingSlashes error:nil];
        NSString* encoded = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        // --additional-mcp-config takes exactly one value and is accepted before
        // subcommands, so prepending it leaves prompts, -- and subcommands intact.
        NSMutableArray<NSString*>* arguments = [NSMutableArray arrayWithObjects:@"--additional-mcp-config", encoded, nil];
        for(int i = 1; i < argc; ++i) [arguments addObject:@(argv[i])];
        return launcher::execute(copilot, arguments, @"tm-copilot");
    }
}
