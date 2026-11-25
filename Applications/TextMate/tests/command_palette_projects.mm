#import "../src/CommandPaletteProjects.h"

static void Check(BOOL condition, NSString* message)
{
	if(!condition) { fprintf(stderr, "%s\n", message.UTF8String); exit(1); }
}

static void Git(NSString* executable, NSString* directory, NSArray* arguments)
{
	NSTask* task = [NSTask new];
	task.executableURL = [NSURL fileURLWithPath:executable];
	task.arguments = [@[@"-C", directory] arrayByAddingObjectsFromArray:arguments];
	task.standardOutput = task.standardError = NSFileHandle.fileHandleWithNullDevice;
	Check([task launchAndReturnError:nil], @"Could not run fixture Git");
	[task waitUntilExit];
	Check(task.terminationStatus == 0, [@"Fixture Git failed: " stringByAppendingString:arguments.description]);
}

int main(int argc, char const* argv[])
{
	@autoreleasepool {
		Check(argc == 2, @"Expected Git executable argument");
		NSString* git = @(argv[1]);
		NSString* temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
		NSFileManager* fs = NSFileManager.defaultManager;
		NSString* root = [temporary stringByAppendingPathComponent:@"main space é\ncheckout"];
		[fs createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
		root = CommandPaletteCanonicalPath(root);
		Git(git, root, @[@"init", @"-b", @"main"]);
		Git(git, root, @[@"-c", @"user.name=Test", @"-c", @"user.email=test@example.invalid", @"-c", @"commit.gpgsign=false", @"-c", @"core.hooksPath=/dev/null", @"commit", @"--allow-empty", @"-m", @"Initial"]);
		NSString* linked = CommandPaletteCanonicalPath([temporary stringByAppendingPathComponent:@"linked space é\ncheckout"]);
		Git(git, root, @[@"worktree", @"add", @"-b", @"topic/palette", linked]);
		NSString* detached = CommandPaletteCanonicalPath([temporary stringByAppendingPathComponent:@"detached"]);
		Git(git, root, @[@"worktree", @"add", @"--detach", detached]);
		Git(git, root, @[@"worktree", @"lock", @"--reason", @"Keep this checkout", detached]);
		NSString* missing = [temporary stringByAppendingPathComponent:@"missing"];
		Git(git, root, @[@"worktree", @"add", @"-b", @"missing", missing]);
		[fs removeItemAtPath:missing error:nil];
		NSString* plain = [temporary stringByAppendingPathComponent:@"non-git"];
		[fs createDirectoryAtPath:plain withIntermediateDirectories:YES attributes:nil error:nil];
		Check([CommandPaletteRepositoryName(@"https://github.com/team/textmate.git\n") isEqual:@"textmate"], @"HTTPS remote name");
		Check([CommandPaletteRepositoryName(@"git@github.com:team/textmate.git") isEqual:@"textmate"], @"scp-style remote name");
		Check([CommandPaletteRepositoryName(@"git@host:textmate") isEqual:@"textmate"], @"scp-style remote without owner");
		Check([CommandPaletteRepositoryName(@"/srv/repos/textmate.git/") isEqual:@"textmate"], @"Local path remote name");
		Check(CommandPaletteRepositoryName(@"") == nil, @"Empty remote has no name");
		Git(git, root, @[@"remote", @"add", @"origin", @"https://example.invalid/team/palette-project.git"]);
		NSDictionary* entries = CommandPaletteWorktrees(@[root, linked, plain], git);
		Check([entries[root][@"repositoryName"] isEqual:@"palette-project"], @"Project name comes from the origin remote");
		Check([entries[linked][@"repositoryName"] isEqual:@"palette-project"], @"Linked worktrees share the project name");
		Check(entries[root][@"layout"] == nil, @"Unmarked repositories have no layout");
		Check(CommandPaletteUsesWorktreeLayout(@{ @"repositoryPath": @"/Users/me/Development/textmate/develop", @"repositoryName": @"textmate" }), @"A main checkout inside a folder named after the repository uses worktrees");
		Check(CommandPaletteUsesWorktreeLayout(@{ @"repositoryPath": @"/Users/me/Development/TextMate/develop", @"repositoryName": @"textmate" }), @"Folder name comparison ignores case");
		Check(!CommandPaletteUsesWorktreeLayout(@{ @"repositoryPath": @"/Users/me/Development/textmate", @"repositoryName": @"textmate" }), @"A repository at the top level does not use worktrees");
		Check(CommandPaletteUsesWorktreeLayout(@{ @"repositoryPath": @"/tmp/anything/main", @"layout": @"worktrees" }), @"The layout marker enables worktrees");
		Check(!CommandPaletteUsesWorktreeLayout(@{ @"layout": @"worktrees" }), @"Non-repositories never use worktrees");
		Git(git, root, @[@"config", @"textmate.layout", @"worktrees"]);
		Check([CommandPaletteWorktrees(@[linked], git)[linked][@"layout"] isEqual:@"worktrees"], @"Discovery reads the layout marker");
		Git(git, root, @[@"config", @"--unset", @"textmate.layout"]);
		Check(entries.count == 3, [@"Discover main and linked worktrees, excluding missing and non-Git directories: " stringByAppendingString:entries.description]);
		Check([entries[root][@"branchLabel"] isEqual:@"main"], @"Main branch label");
		Check([entries[linked][@"branchLabel"] isEqual:@"topic/palette"], @"Linked branch and unusual path survive NUL parsing");
		Check([entries[detached][@"branchLabel"] hasPrefix:@"detached "], @"Detached commit label");
		Check([entries[detached][@"locked"] isEqual:@"Keep this checkout"], @"Lock reason survives parsing");
		Check([entries[root][@"relatedPaths"] count] == 3, @"Related worktree discovery");
		Check([entries[root][@"repositoryPath"] isEqual:root], @"Project group identifies the main checkout");
		Check([entries[linked][@"repositoryPath"] isEqual:root], @"Linked checkouts share the project group");
		Check([entries[detached][@"repositoryPath"] isEqual:root], @"Detached checkouts share the project group");
		NSString* nested = [root stringByAppendingPathComponent:@"src"];
		[fs createDirectoryAtPath:nested withIntermediateDirectories:YES attributes:nil error:nil];
		Check([CommandPaletteWorktreeForPath(entries, nested)[@"branchLabel"] isEqual:@"main"], @"Subdirectory projects inherit the branch");
		Check(CommandPaletteWorktreeForPath(entries, [root stringByAppendingString:@"-other"]) == nil, @"Directory boundary prevents false matches");
		NSString* alias = [temporary stringByAppendingPathComponent:@"alias"];
		[fs createSymbolicLinkAtPath:alias withDestinationPath:root error:nil];
		Check([CommandPaletteWorktreeForPath(entries, alias)[@"path"] isEqual:root], @"Symlinks resolve to the same workspace identity");
		NSArray* folded = CommandPaletteWorkspacePaths(@[nested, root, alias, linked, plain], entries);
		Check([folded isEqual:@[root, linked, CommandPaletteCanonicalPath(plain)]], @"Historical subdirectories, roots, and symlinks fold into one workspace while plain projects remain");
		NSDictionary* nestedRepository = @{ nested: @{ @"path": nested } };
		NSMutableDictionary* withNested = [entries mutableCopy];
		[withNested addEntriesFromDictionary:nestedRepository];
		Check([CommandPaletteWorkspacePaths(@[root, nested], withNested) isEqual:@[root, nested]], @"An independent nested repository remains a separate checkout");
		Git(git, nested, @[@"init", @"-b", @"nested"]);
		NSDictionary* discoveredNested = CommandPaletteWorktrees(@[root, nested], git);
		Check([discoveredNested[nested][@"repositoryPath"] isEqual:nested], @"Original subdirectory seeds discover new nested repositories instead of folding them into cached parent metadata");
		Check(discoveredNested[nested][@"repositoryName"] == nil, @"Repositories without an origin remote have no project name");
		NSDictionary* linkedEntries = CommandPaletteWorktrees(@[linked], git);
		Check([linkedEntries[root][@"relatedPaths"] isEqual:entries[root][@"relatedPaths"]], @"Discovery also works from linked checkouts");
		Check([linkedEntries[linked][@"repositoryPath"] isEqual:root], @"Group identity is stable when querying a linked checkout");
		NSString* oldGitDir = getenv("GIT_DIR") ? @(getenv("GIT_DIR")) : nil;
		setenv("GIT_DIR", "/does-not-exist", 1);
		Check(CommandPaletteWorktrees(@[root], git).count == 3, @"Inherited Git overrides do not redirect discovery");
		if(oldGitDir) setenv("GIT_DIR", oldGitDir.UTF8String, 1); else unsetenv("GIT_DIR");
		Git(git, root, @[@"checkout", @"-b", @"changed-branch"]);
		Check([CommandPaletteWorktrees(@[root], git)[root][@"branchLabel"] isEqual:@"changed-branch"], @"Refresh sees branch changes");
		NSProgress* cancelled = [NSProgress progressWithTotalUnitCount:1];
		[cancelled cancel];
		Check(CommandPaletteWorktrees(@[root], git, cancelled).count == 0, @"Cancelled popup discovery does no work");
		Check(CommandPaletteWorktrees(@[root], nil).count == 0, @"Projects remain usable without Git");
		NSString* stalledGit = [temporary stringByAppendingPathComponent:@"stalled-git"];
		[@"#!/bin/sh\nexec /bin/sleep 5\n" writeToFile:stalledGit atomically:YES encoding:NSUTF8StringEncoding error:nil];
		[fs setAttributes:@{NSFilePosixPermissions: @0700} ofItemAtPath:stalledGit error:nil];
		NSDate* start = NSDate.date;
		Check(CommandPaletteWorktrees(@[root], stalledGit).count == 0, @"Unavailable repositories return no metadata");
		Check(-start.timeIntervalSinceNow < 4, @"Git discovery has a bounded wait");
		[fs removeItemAtPath:temporary error:nil];
		puts("Project worktree discovery checks passed.");
	}
	return 0;
}
