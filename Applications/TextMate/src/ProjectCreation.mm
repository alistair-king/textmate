#import "ProjectCreation.h"
#include <unistd.h>

NSString* const kProjectCreationLayoutConfigKey = @"textmate.layout";

static NSError* Failure (NSString* message)
{
	return [NSError errorWithDomain:@"com.macromates.TextMate.ProjectCreation" code:1 userInfo:@{ NSLocalizedDescriptionKey: message }];
}

static NSString* Contents (FILE* fp)
{
	off_t size = lseek(fileno(fp), 0, SEEK_END);
	if(size <= 0)
		return @"";
	NSMutableData* data = [NSMutableData dataWithLength:size];
	if(pread(fileno(fp), data.mutableBytes, size, 0) != size)
		return @"";
	NSString* text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
	return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// No deadline: a clone takes as long as it takes. Output goes to files so a
// chatty clone cannot fill a pipe, and prompts are disabled so a missing
// credential fails instead of hanging.
static BOOL RunGit (NSString* git, NSString* directory, NSArray<NSString*>* arguments, NSString** output, NSError** error)
{
	FILE* out = tmpfile();
	FILE* err = tmpfile();
	if(!out || !err)
	{
		if(out) fclose(out);
		if(err) fclose(err);
		if(error) *error = Failure(@"Unable to create temporary files for Git.");
		return NO;
	}

	NSMutableDictionary* environment = [NSProcessInfo.processInfo.environment mutableCopy];
	for(NSString* key in @[ @"GIT_DIR", @"GIT_WORK_TREE", @"GIT_INDEX_FILE", @"GIT_OBJECT_DIRECTORY", @"GIT_ALTERNATE_OBJECT_DIRECTORIES", @"GIT_COMMON_DIR", @"GIT_NAMESPACE", @"GIT_PREFIX" ])
		[environment removeObjectForKey:key];
	environment[@"GIT_TERMINAL_PROMPT"] = @"0";

	NSTask* task = [NSTask new];
	task.executableURL       = [NSURL fileURLWithPath:git];
	task.currentDirectoryURL = [NSURL fileURLWithPath:directory isDirectory:YES];
	task.arguments           = arguments;
	task.environment         = environment;
	task.standardInput       = NSFileHandle.fileHandleWithNullDevice;
	task.standardOutput      = [[NSFileHandle alloc] initWithFileDescriptor:fileno(out) closeOnDealloc:NO];
	task.standardError       = [[NSFileHandle alloc] initWithFileDescriptor:fileno(err) closeOnDealloc:NO];

	NSError* launchError = nil;
	BOOL success = [task launchAndReturnError:&launchError];
	if(success)
	{
		[task waitUntilExit];
		success = task.terminationReason == NSTaskTerminationReasonExit && task.terminationStatus == 0;
	}

	NSString* standardOutput = Contents(out);
	NSString* standardError  = Contents(err);
	fclose(out);
	fclose(err);

	if(success && output)
		*output = standardOutput;
	else if(!success && error)
		*error = Failure(launchError.localizedDescription ?: (standardError.length ? standardError : [NSString stringWithFormat:@"git %@ failed.", arguments.firstObject]));
	return success;
}

static BOOL Exists (NSString* path)
{
	// Do not follow symbolic links: a dangling link still occupies the name.
	return [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] != nil;
}

NSString* ProjectCreationNameProblem (NSString* name)
{
	if(!name.length)
		return @"Enter a project name.";
	if([name containsString:@"/"] || [name containsString:@":"] || [name hasPrefix:@"."])
		return @"A project name cannot contain “/” or “:”, or start with “.”.";
	return nil;
}

NSString* ProjectCreationBranchDirectoryName (NSString* branch)
{
	return [branch stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
}

NSString* ProjectCreationWorktreeContainer (NSString* mainCheckout)
{
	return mainCheckout.stringByStandardizingPath.stringByDeletingLastPathComponent;
}

NSString* ProjectCreationCreate (NSString* parent, NSString* name, ProjectCreationLayout layout, NSString* remoteURL, NSString* git, NSError** error)
{
	name      = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	remoteURL = [remoteURL stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	if(NSString* problem = ProjectCreationNameProblem(name))
	{
		if(error) *error = Failure(problem);
		return nil;
	}

	NSFileManager* fm = NSFileManager.defaultManager;
	BOOL isDirectory = NO;
	if(![fm fileExistsAtPath:parent isDirectory:&isDirectory] || !isDirectory)
	{
		if(error) *error = Failure([NSString stringWithFormat:@"The folder “%@” does not exist.", parent.stringByAbbreviatingWithTildeInPath]);
		return nil;
	}

	NSString* target = [parent stringByAppendingPathComponent:name];
	if(Exists(target))
	{
		if(error) *error = Failure([NSString stringWithFormat:@"“%@” already exists.", target.stringByAbbreviatingWithTildeInPath]);
		return nil;
	}
	if(![fm createDirectoryAtPath:target withIntermediateDirectories:NO attributes:nil error:error])
		return nil;

	// The default branch is only known after cloning, so the worktrees layout
	// checks out into a temporary folder and renames it after the branch.
	NSString* checkout = target;
	if(layout == ProjectCreationLayoutWorktrees)
		checkout = [target stringByAppendingPathComponent:[@".textmate-new-" stringByAppendingString:NSUUID.UUID.UUIDString]];

	BOOL success = remoteURL.length
		? RunGit(git, target, @[ @"clone", @"--", remoteURL, checkout ], nil, error)
		: RunGit(git, target, @[ @"init", checkout ], nil, error);

	if(success && layout == ProjectCreationLayoutWorktrees)
	{
		NSString* branch = nil;
		if((success = RunGit(git, checkout, @[ @"symbolic-ref", @"--short", @"HEAD" ], &branch, error)))
		{
			NSString* named = [target stringByAppendingPathComponent:ProjectCreationBranchDirectoryName(branch)];
			if((success = [fm moveItemAtPath:checkout toPath:named error:error]))
			{
				checkout = named;
				success = RunGit(git, checkout, @[ @"config", kProjectCreationLayoutConfigKey, @"worktrees" ], nil, error);
			}
		}
	}

	if(!success)
	{
		[fm removeItemAtPath:target error:nil];
		return nil;
	}
	return checkout;
}

NSString* ProjectCreationAddWorktree (NSString* mainCheckout, NSString* branch, NSString* git, NSError** error)
{
	branch = [branch stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	if(!branch.length || [branch hasPrefix:@"-"] || !RunGit(git, mainCheckout, @[ @"check-ref-format", @"--branch", branch ], nil, nil))
	{
		if(error) *error = Failure(branch.length ? [NSString stringWithFormat:@"“%@” is not a valid branch name.", branch] : @"Enter a branch name.");
		return nil;
	}

	NSString* target = [ProjectCreationWorktreeContainer(mainCheckout) stringByAppendingPathComponent:ProjectCreationBranchDirectoryName(branch)];
	if(Exists(target))
	{
		if(error) *error = Failure([NSString stringWithFormat:@"“%@” already exists.", target.stringByAbbreviatingWithTildeInPath]);
		return nil;
	}

	NSArray* arguments;
	if(RunGit(git, mainCheckout, @[ @"rev-parse", @"--verify", @"--quiet", [@"refs/heads/" stringByAppendingString:branch] ], nil, nil))
		arguments = @[ @"worktree", @"add", target, branch ];
	else if(RunGit(git, mainCheckout, @[ @"rev-parse", @"--verify", @"--quiet", [@"refs/remotes/origin/" stringByAppendingString:branch] ], nil, nil))
		arguments = @[ @"worktree", @"add", @"--track", @"-b", branch, target, [@"origin/" stringByAppendingString:branch] ];
	else
		arguments = @[ @"worktree", @"add", @"-b", branch, target, @"HEAD" ];

	return RunGit(git, mainCheckout, arguments, nil, error) ? target : nil;
}

NSString* ProjectCreationImportPath (NSString* folder)
{
	NSFileManager* fm = NSFileManager.defaultManager;
	if([fm fileExistsAtPath:[folder stringByAppendingPathComponent:@".git"]])
		return folder;

	// A container holds exactly one checkout whose .git is a directory (the
	// main checkout) and linked worktrees whose .git is a file.
	NSString* main = nil;
	NSMutableArray<NSString*>* linked = [NSMutableArray array];
	for(NSString* child in [fm contentsOfDirectoryAtPath:folder error:nil])
	{
		BOOL isDirectory = NO;
		NSString* checkout = [folder stringByAppendingPathComponent:child];
		if(![fm fileExistsAtPath:[checkout stringByAppendingPathComponent:@".git"] isDirectory:&isDirectory])
			continue;
		if(!isDirectory)
			[linked addObject:checkout];
		else if(main)
			return folder;
		else
			main = checkout;
	}
	if(!main)
		return folder;

	// A lone repository inside an ordinary folder (vendor/library) is not a
	// container: require the layout marker or a sibling worktree of it.
	NSString* gitDir = [main stringByAppendingPathComponent:@".git"];
	NSString* config = [NSString stringWithContentsOfFile:[gitDir stringByAppendingPathComponent:@"config"] encoding:NSUTF8StringEncoding error:nil];
	NSRegularExpression* marker = [NSRegularExpression regularExpressionWithPattern:@"^\\s*\\[textmate\\][^\\[]*^\\s*layout\\s*=\\s*worktrees\\s*$" options:NSRegularExpressionCaseInsensitive|NSRegularExpressionAnchorsMatchLines error:nil];
	if(config && [marker firstMatchInString:config options:0 range:NSMakeRange(0, config.length)])
		return main;

	NSString* worktrees = [[gitDir stringByAppendingPathComponent:@"worktrees"].stringByResolvingSymlinksInPath stringByAppendingString:@"/"];
	for(NSString* checkout in linked)
	{
		NSString* link = [NSString stringWithContentsOfFile:[checkout stringByAppendingPathComponent:@".git"] encoding:NSUTF8StringEncoding error:nil];
		if(![link hasPrefix:@"gitdir:"])
			continue;
		NSString* target = [[link substringFromIndex:7] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
		if(!target.isAbsolutePath) // worktree.useRelativePaths
			target = [checkout stringByAppendingPathComponent:target];
		if([target.stringByStandardizingPath.stringByResolvingSymlinksInPath hasPrefix:worktrees])
			return main;
	}
	return folder;
}
