#import "ProjectChanges.h"
#import <document/OakDocument Private.h>
#include <xdiff.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <unistd.h>
#include <chrono>

namespace {
constexpr NSUInteger fileLimit = 4 * 1024 * 1024;
static double Now() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
static NSDictionary* Error(NSString* message) { return @{ @"error": message }; }

static NSDictionary* Git(NSString* directory, NSArray<NSString*>* arguments)
{
	if(!directory.length) return Error(@"Open a folder in a Git repository to review its changes.");
	NSTask* task = [[NSTask alloc] init];
	task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/git"];
	task.arguments = [@[@"--no-optional-locks", @"-c", @"core.fsmonitor=false", @"-C", directory] arrayByAddingObjectsFromArray:arguments];
	NSMutableDictionary* environment = [NSProcessInfo.processInfo.environment mutableCopy];
	// This view always reviews the requested directory, independently of any
	// Git overrides inherited when TextMate was launched from a shell.
	for(NSString* key in [environment.allKeys copy])
		if([key hasPrefix:@"GIT_"]) [environment removeObjectForKey:key];
	environment[@"GIT_OPTIONAL_LOCKS"] = @"0";
	environment[@"GIT_TERMINAL_PROMPT"] = @"0";
	task.environment = environment;
	NSPipe* pipe = [NSPipe pipe];
	task.standardOutput = pipe;
	task.standardError = [NSFileHandle fileHandleWithNullDevice];
	task.standardInput = [NSFileHandle fileHandleWithNullDevice];
	NSError* error;
	if(![task launchAndReturnError:&error]) return Error(@"Git could not be started. Install the macOS command line tools and try again.");
	[pipe.fileHandleForWriting closeFile];
	int fd = pipe.fileHandleForReading.fileDescriptor;
	fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
	NSMutableData* output = [NSMutableData data];
	double deadline = Now()+10;
	BOOL eof = NO;
	NSString* problem = nil;
	while(task.running || !eof)
	{
		if(Now() >= deadline) { problem = @"Git took too long to respond. Try refreshing the view."; break; }
		if(eof) { [NSThread sleepForTimeInterval:0.01]; continue; }
		pollfd descriptor = { fd, POLLIN, 0 };
		if(poll(&descriptor, 1, 100) < 0 && errno != EINTR) { problem = @"Git output could not be read."; break; }
		char bytes[16384];
		ssize_t count = read(fd, bytes, sizeof(bytes));
		if(count == 0) eof = YES;
		else if(count > 0) {
			if(output.length + count > fileLimit) { problem = @"This change is too large to preview (limit 4 MB)."; break; }
			[output appendBytes:bytes length:count];
		} else if(errno != EAGAIN && errno != EINTR) { problem = @"Git output could not be read."; break; }
	}
	if(problem && task.running) kill(task.processIdentifier, SIGKILL);
	[task waitUntilExit];
	[pipe.fileHandleForReading closeFile];
	return problem ? Error(problem) : @{ @"data": output, @"status": @(task.terminationStatus) };
}
static NSString* GitString(NSDictionary* result)
{
	if(result[@"error"] || [result[@"status"] intValue]) return nil;
	return [[[NSString alloc] initWithData:result[@"data"] encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
}
static NSString* Status(NSString* flags, BOOL unsaved)
{
	NSString* status = [flags containsString:@"U"] || [@[@"AA", @"DD"] containsObject:flags] ? @"Conflict" :
		[flags containsString:@"D"] ? @"Deleted" : [flags containsString:@"?"] || [flags containsString:@"A"] ? @"New file" : @"Modified";
	return unsaved ? [status stringByAppendingString:@" · Unsaved"] : status;
}
static NSData* ReadFile(NSString* path, NSString** error)
{
	struct stat info;
	if(lstat(path.fileSystemRepresentation, &info)) { *error = @"The file is no longer available. Refresh to update the list."; return nil; }
	if(S_ISLNK(info.st_mode)) {
		char target[PATH_MAX];
		ssize_t size = readlink(path.fileSystemRepresentation, target, sizeof(target));
		if(size >= 0) return [NSData dataWithBytes:target length:size];
		*error = @"The symbolic link could not be read."; return nil;
	}
	int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NONBLOCK | O_NOFOLLOW);
	if(fd < 0) { *error = @"The file could not be read."; return nil; }
	if(fstat(fd, &info) || !S_ISREG(info.st_mode)) { close(fd); *error = @"This entry is a directory or submodule. Review its changes in that repository."; return nil; }
	if(info.st_size > fileLimit) { close(fd); *error = @"This file is too large to preview (limit 4 MB)."; return nil; }
	NSMutableData* data = [NSMutableData data];
	char bytes[16384];
	ssize_t size;
	while((size = read(fd, bytes, sizeof(bytes))) > 0) {
		[data appendBytes:bytes length:size];
		if(data.length > fileLimit) { *error = @"This file is too large to preview (limit 4 MB)."; break; }
	}
	if(size < 0) *error = @"The file could not be read.";
	close(fd);
	return *error ? nil : data;
}
}

@implementation ProjectChangesBuffer
{
	ng::detail::storage_t _storage;
	BOOL _tooLarge;
}
+ (instancetype)captureDocument:(OakDocument*)document
{
	ProjectChangesBuffer* result = [[self alloc] init];
	result->_tooLarge = [document buffer].size() > fileLimit;
	if(!result->_tooLarge) result->_storage = [document buffer].storage();
	return result;
}
- (NSData*)data
{
	if(_tooLarge) return nil;
	NSMutableData* data = [NSMutableData data];
	for(auto const& piece : _storage) [data appendBytes:piece.data() length:piece.size()];
	return data;
}
@end

NSDictionary* ProjectChangesSnapshot(NSString* directory, NSDictionary<NSString*, ProjectChangesBuffer*>* buffers)
{
	NSDictionary* rootResult = Git(directory, @[@"rev-parse", @"--show-toplevel"]);
	NSString* root = GitString(rootResult);
	if(!root.length) return Error(rootResult[@"error"] ?: @"Open a folder in a Git repository to review its changes.");
	NSDictionary* status = Git(root, @[@"status", @"--porcelain=v1", @"-z", @"--untracked-files=all", @"--no-renames"]);
	if(status[@"error"] || [status[@"status"] intValue]) return Error(status[@"error"] ?: @"The repository's changed files could not be read.");
	NSData* data = status[@"data"];
	NSMutableDictionary<NSString*, NSString*>* paths = [NSMutableDictionary dictionary];
	char const* bytes = static_cast<char const*>(data.bytes);
	NSUInteger start = 0;
	for(NSUInteger i = 0; i < data.length; ++i) if(bytes[i] == '\0') {
		if(i-start >= 4) {
			NSString* flags = [[NSString alloc] initWithBytes:bytes+start length:2 encoding:NSUTF8StringEncoding];
			NSString* path = [[NSString alloc] initWithBytes:bytes+start+3 length:i-start-3 encoding:NSUTF8StringEncoding];
			if(path && flags) paths[path] = flags;
		}
		start = i+1;
	}
	NSString* prefix = [root stringByAppendingString:@"/"];
	NSMutableDictionary* bufferPaths = [NSMutableDictionary dictionary];
	for(NSString* original in buffers) {
		char resolved[PATH_MAX];
		NSString* parent = [original stringByDeletingLastPathComponent];
		NSString* absolute = [(realpath(parent.fileSystemRepresentation, resolved) ? @(resolved) : parent) stringByAppendingPathComponent:original.lastPathComponent];
		if([absolute hasPrefix:prefix]) {
			NSString* relative = [absolute substringFromIndex:prefix.length];
			if(!paths[relative]) paths[relative] = @" M";
			bufferPaths[relative] = original;
		}
	}
	NSMutableArray* files = [NSMutableArray array];
	for(NSString* path in [paths.allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
		NSString* absolute = [root stringByAppendingPathComponent:path];
		BOOL unsaved = bufferPaths[path] != nil;
		[files addObject:@{ @"path": path, @"absolutePath": absolute, @"flags": paths[path],
			@"status": Status(paths[path], unsaved), @"unsaved": @(unsaved), @"bufferPath": bufferPaths[path] ?: absolute }];
	}
	NSString* head = GitString(Git(root, @[@"rev-parse", @"--verify", @"HEAD"]));
	NSString* branch = GitString(Git(root, @[@"symbolic-ref", @"--quiet", @"--short", @"HEAD"]));
	return @{ @"root": root, @"files": files, @"head": head ?: @"", @"branch": branch ?: @"Detached HEAD" };
}

NSDictionary* ProjectChangesDiff(NSDictionary* snapshot, NSDictionary* file, NSDictionary<NSString*, ProjectChangesBuffer*>* buffers)
{
	NSData* before = [NSData data];
	NSString* flags = file[@"flags"];
	if([snapshot[@"head"] length]) {
		NSDictionary* blob = Git(snapshot[@"root"], @[@"cat-file", @"blob", [NSString stringWithFormat:@"%@:%@", snapshot[@"head"], file[@"path"]]]);
		if(blob[@"error"]) return Error(blob[@"error"]);
		if([blob[@"status"] intValue]) {
			if(![flags containsString:@"A"] && ![flags containsString:@"?"])
				return Error(@"The committed version is not a text file or could not be read. Refresh and try again.");
		} else before = blob[@"data"];
	}
	NSString* problem = nil;
	NSData* after;
	if(ProjectChangesBuffer* buffer = buffers[file[@"bufferPath"]]) {
		after = buffer.data;
		if(!after) return Error(@"This unsaved buffer is too large to preview (limit 4 MB).");
	} else if([flags containsString:@"D"]) after = [NSData data];
	else after = ReadFile(file[@"absolutePath"], &problem);
	if(!after) return Error(problem ?: @"The current file could not be read.");
	if(memchr(before.bytes, 0, before.length) || memchr(after.bytes, 0, after.length))
		return Error(@"Binary file changed. A text diff is not available.");
	NSString* oldText = [[NSString alloc] initWithData:before encoding:NSUTF8StringEncoding];
	NSString* newText = [[NSString alloc] initWithData:after encoding:NSUTF8StringEncoding];
	if(!oldText || !newText) return Error(@"This file uses an encoding other than UTF-8. A text diff is not available.");
	// Editor buffers normalize newlines. Compare like-for-like for an unsaved
	// buffer so a CRLF file does not appear changed on every line.
	if([file[@"unsaved"] boolValue]) {
		before = [[oldText stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
		after = [[newText stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
	}
	mmfile_t a = { (char*)before.bytes, (long)before.length }, b = { (char*)after.bytes, (long)after.length };
	xpparam_t parameters = {};
	parameters.flags = XDF_HISTOGRAM_DIFF;
	xdemitconf_t config = {};
	config.ctxlen = 3;
	NSMutableData* output = [NSMutableData data];
	xdemitcb_t callback = {};
	callback.priv = (__bridge void*)output;
	callback.out_line = [](void* context, mmbuffer_t* chunks, int count) -> int {
		NSMutableData* data = (__bridge NSMutableData*)context;
		for(int i = 0; i < count; ++i) {
			if(data.length + chunks[i].size > 3*fileLimit) return -1;
			[data appendBytes:chunks[i].ptr length:chunks[i].size];
		}
		return 0;
	};
	if(xdl_diff(&a, &b, &parameters, &config, &callback) < 0) return Error(@"This diff is too large to display.");
	NSString* diff = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
	NSMutableArray* hunks = [NSMutableArray array];
	NSRegularExpression* pattern = [NSRegularExpression regularExpressionWithPattern:@"^@@ -[0-9]+(?:,[0-9]+)? \\+([0-9]+)(?:,[0-9]+)? @@" options:NSRegularExpressionAnchorsMatchLines error:nil];
	NSArray<NSTextCheckingResult*>* matches = [pattern matchesInString:diff options:0 range:NSMakeRange(0, diff.length)];
	for(NSUInteger i = 0; i < matches.count; ++i) {
		NSRange range = matches[i].range;
		NSUInteger end = i+1 < matches.count ? matches[i+1].range.location : diff.length;
		[hunks addObject:@{ @"offset": @(range.location), @"length": @(end-range.location),
			@"line": @(MAX(1, [[diff substringWithRange:[matches[i] rangeAtIndex:1]] integerValue])) }];
	}
	NSUInteger added = 0, removed = 0;
	for(NSString* line in [diff componentsSeparatedByString:@"\n"]) {
		if([line hasPrefix:@"+"]) ++added;
		if([line hasPrefix:@"-"]) ++removed;
	}
	return @{ @"text": diff.length ? diff : @"No text differences against the last commit. File permissions or the staging area may differ.",
		@"hunks": hunks, @"added": @(added), @"removed": @(removed) };
}
