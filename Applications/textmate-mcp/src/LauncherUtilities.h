#pragma once
#import <Foundation/Foundation.h>
#include <libproc.h>

namespace launcher {
inline void prepareReviewEnvironment() {
    // Capture the agent's workspace before its MCP host chooses a helper cwd.
    NSString* directory = NSFileManager.defaultManager.currentDirectoryPath;
    setenv("TM_A2A_PROJECT", directory.fileSystemRepresentation, 1);
    if(!getenv("TM_A2A_AUTOMATIC")) setenv("TM_A2A_AUTOMATIC", "1", 1);
    // Define optional values so hosts that expand ${VAR} can always resolve them.
    if(!getenv("TM_CODEX_COMMAND")) setenv("TM_CODEX_COMMAND", "", 1);
}
inline NSString* executable(NSString* path) {
    BOOL directory = NO;
    return [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] && !directory &&
        [NSFileManager.defaultManager isExecutableFileAtPath:path] ? path : nil;
}
inline NSString* readable(NSString* path) {
    BOOL directory = NO;
    return [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] && !directory &&
        [NSFileManager.defaultManager isReadableFileAtPath:path] ? path : nil;
}
inline NSString* find(NSString* name, NSString* override, NSArray<NSString*>* fallbacks) {
    NSDictionary* environment = NSProcessInfo.processInfo.environment;
    if([environment[override] length]) return executable(environment[override]);
    for(NSString* directory in [environment[@"PATH"] componentsSeparatedByString:@":"])
        if(NSString* path = executable([(directory.length ? directory : @".") stringByAppendingPathComponent:name])) return path;
    for(NSString* path in fallbacks) if(NSString* found = executable(path)) return found;
    return nil;
}
inline NSString* helper() {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if(proc_pidpath(getpid(), path, sizeof(path)) <= 0) return nil;
    return executable([[@(path) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"textmate-mcp"]);
}
// A file shipped beside the launchers: in the app bundle it lives in Contents/Resources,
// in a build tree it is copied next to the binary.
inline NSString* resource(NSString* name) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if(proc_pidpath(getpid(), path, sizeof(path)) <= 0) return nil;
    NSString* directory = [@(path) stringByDeletingLastPathComponent];
    for(NSString* candidate in @[directory, [[directory stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Resources"]])
        if(NSString* found = readable([candidate stringByAppendingPathComponent:name])) return found;
    return nil;
}
inline int execute(NSString* path, NSArray<NSString*>* arguments, NSString* label) {
    std::vector<char*> processArguments;
    processArguments.push_back((char*)path.UTF8String);
    for(NSString* argument in arguments) processArguments.push_back((char*)argument.UTF8String);
    processArguments.push_back(nullptr);
    execv(path.fileSystemRepresentation, processArguments.data());
    fprintf(stderr, "%s: Cannot start the agent: %s\n", label.UTF8String, strerror(errno));
    return 1;
}
}
