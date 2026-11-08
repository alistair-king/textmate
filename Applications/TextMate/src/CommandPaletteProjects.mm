#import "CommandPaletteProjects.h"
#include <signal.h>
#include <unistd.h>

NSString* CommandPaletteCanonicalPath(NSString* path)
{
	return path.stringByStandardizingPath.stringByResolvingSymlinksInPath.precomposedStringWithCanonicalMapping;
}

static BOOL ContainsPath(NSString* root, NSString* path)
{
	return [root isEqual:path] || [path hasPrefix:[root isEqual:@"/"] ? root : [root stringByAppendingString:@"/"]];
}

NSDictionary* CommandPaletteWorktreeForPath(NSDictionary<NSString*, NSDictionary*>* worktrees, NSString* path)
{
	NSString* canonical = CommandPaletteCanonicalPath(path);
	NSString* best = nil;
	for(NSString* root in worktrees)
		if(ContainsPath(root, canonical) && root.length > best.length) best = root;
	return best ? worktrees[best] : nil;
}

NSArray<NSString*>* CommandPaletteWorkspacePaths(NSArray<NSString*>* paths, NSDictionary<NSString*, NSDictionary*>* worktrees)
{
	NSMutableOrderedSet* result = [NSMutableOrderedSet orderedSet];
	for(NSString* path in paths)
		[result addObject:CommandPaletteWorktreeForPath(worktrees, path)[@"path"] ?: CommandPaletteCanonicalPath(path)];
	return result.array;
}

static NSData* WorktreeList(NSString* directory, NSString* git)
{
	// File-backed output avoids pipe deadlocks, with a deadline for unavailable
	// repositories/filesystems. No shell, prompts, inherited Git overrides, or
	// index refreshes are involved in discovery.
	FILE* output = tmpfile();
	if(!output) return nil;
	NSFileHandle* handle = [[NSFileHandle alloc] initWithFileDescriptor:fileno(output) closeOnDealloc:NO];
	NSTask* task = [NSTask new];
	task.executableURL = [NSURL fileURLWithPath:git];
	task.arguments = @[@"--no-optional-locks", @"-C", directory, @"worktree", @"list", @"--porcelain", @"-z"];
	NSMutableDictionary* environment = [NSProcessInfo.processInfo.environment mutableCopy];
	for(NSString* key in environment.allKeys)
		if([key hasPrefix:@"GIT_"]) [environment removeObjectForKey:key];
	environment[@"GIT_TERMINAL_PROMPT"] = @"0";
	task.environment = environment;
	task.standardOutput = handle;
	task.standardError = task.standardInput = NSFileHandle.fileHandleWithNullDevice;
	dispatch_semaphore_t exited = dispatch_semaphore_create(0);
	task.terminationHandler = ^(NSTask*){ dispatch_semaphore_signal(exited); };
	NSData* result = nil;
	if([task launchAndReturnError:nil])
	{
		BOOL timedOut = dispatch_semaphore_wait(exited, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) != 0;
		if(timedOut && task.running) kill(task.processIdentifier, SIGKILL);
		[task waitUntilExit];
		if(!timedOut && task.terminationStatus == 0)
		{
			off_t size = lseek(fileno(output), 0, SEEK_END);
			if(size >= 0 && size <= 4 * 1024 * 1024)
			{
				[handle seekToFileOffset:0];
				result = [handle readDataToEndOfFile];
			}
		}
	}
	fclose(output);
	return result;
}

NSDictionary<NSString*, NSDictionary*>* CommandPaletteWorktrees(NSArray<NSString*>* paths, NSString* git, NSProgress* progress)
{
	NSMutableDictionary* result = [NSMutableDictionary dictionary];
	if(!git.length) return result;
	NSMutableSet* visited = [NSMutableSet set];
	for(NSString* path in paths)
	{
		if(progress.cancelled) break;
		NSString* canonical = CommandPaletteCanonicalPath(path);
		if([visited containsObject:canonical] || result[canonical]) continue;
		[visited addObject:canonical];
		NSData* data = WorktreeList(canonical, git);
		NSString* text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
		if(!text) continue;
		NSArray<NSString*>* fields = [text componentsSeparatedByString:@"\0"];
		// Git lists the main checkout (or bare repository) first, even when
		// discovery starts in a linked worktree. Its path identifies the group
		// independently of branch names or the linked directories' names.
		NSString* first = fields.firstObject;
		NSString* repositoryPath = [first hasPrefix:@"worktree "] ? CommandPaletteCanonicalPath([first substringFromIndex:9]) : nil;
		NSMutableDictionary* entry = [NSMutableDictionary dictionary];
		NSMutableArray* repositoryRoots = [NSMutableArray array];
		// Git already terminates records with two NULs. Split the original
		// buffer directly so embedded NULs never pass through concatenation.
		for(NSString* field in fields)
		{
			if(!field.length)
			{
				NSString* root = entry[@"worktree"];
				BOOL isDirectory = NO;
				if(root && !entry[@"bare"] && !entry[@"prunable"] && [NSFileManager.defaultManager fileExistsAtPath:root isDirectory:&isDirectory] && isDirectory)
				{
					root = CommandPaletteCanonicalPath(root);
					entry[@"path"] = root;
					NSString* branch = entry[@"branch"];
					if([branch hasPrefix:@"refs/heads/"]) branch = [branch substringFromIndex:11];
					NSString* commit = entry[@"HEAD"] ?: @"";
					entry[@"branchLabel"] = branch ?: [@"detached " stringByAppendingString:[commit substringToIndex:MIN(7, commit.length)]];
					result[root] = [entry copy];
					[repositoryRoots addObject:root];
				}
				entry = [NSMutableDictionary dictionary];
				continue;
			}
			NSRange space = [field rangeOfString:@" "];
			NSString* key = space.location == NSNotFound ? field : [field substringToIndex:space.location];
			entry[key] = space.location == NSNotFound ? @YES : [field substringFromIndex:space.location + 1];
		}
		for(NSString* root in repositoryRoots)
		{
			NSMutableDictionary* metadata = [result[root] mutableCopy];
			metadata[@"relatedPaths"] = [repositoryRoots copy];
			if(repositoryPath) metadata[@"repositoryPath"] = repositoryPath;
			result[root] = metadata;
		}
	}
	return result;
}
