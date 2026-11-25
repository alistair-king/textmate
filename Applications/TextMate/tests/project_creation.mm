#import "../src/ProjectCreation.h"
#import "../src/CommandPaletteProjects.h"

static void Check(BOOL condition, NSString* message)
{
	if(!condition) { fprintf(stderr, "%s\n", message.UTF8String); exit(1); }
}

static NSString* Git(NSString* executable, NSString* directory, NSArray* arguments)
{
	NSPipe* pipe = [NSPipe pipe];
	NSTask* task = [NSTask new];
	task.executableURL = [NSURL fileURLWithPath:executable];
	task.arguments = [@[@"-C", directory, @"-c", @"user.name=Test", @"-c", @"user.email=test@example.invalid", @"-c", @"commit.gpgsign=false", @"-c", @"core.hooksPath=/dev/null"] arrayByAddingObjectsFromArray:arguments];
	task.standardOutput = pipe;
	task.standardError = NSFileHandle.fileHandleWithNullDevice;
	Check([task launchAndReturnError:nil], @"Could not run fixture Git");
	NSData* data = [pipe.fileHandleForReading readDataToEndOfFile];
	[task waitUntilExit];
	Check(task.terminationStatus == 0, [@"Fixture Git failed: " stringByAppendingString:arguments.description]);
	return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSArray* Contents(NSString* directory)
{
	return [[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil] sortedArrayUsingSelector:@selector(compare:)];
}

int main(int argc, char const* argv[])
{
	@autoreleasepool {
		Check(argc == 2, @"Expected Git executable argument");
		NSString* git = @(argv[1]);
		NSFileManager* fm = NSFileManager.defaultManager;
		NSString* temporary = CommandPaletteCanonicalPath([NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]);
		NSString* parent = [temporary stringByAppendingPathComponent:@"Development"];
		[fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];

		// A remote whose default branch is "trunk", with an extra "topic" branch.
		NSString* source = [temporary stringByAppendingPathComponent:@"source"];
		[fm createDirectoryAtPath:source withIntermediateDirectories:YES attributes:nil error:nil];
		Git(git, source, @[@"init", @"-b", @"trunk"]);
		Git(git, source, @[@"commit", @"--allow-empty", @"-m", @"Initial"]);
		Git(git, source, @[@"branch", @"topic"]);

		Check([ProjectCreationNameProblem(@"") length] > 0, @"Empty names are rejected");
		Check([ProjectCreationNameProblem(@"a/b") length] > 0, @"Names with slashes are rejected");
		Check([ProjectCreationNameProblem(@".hidden") length] > 0, @"Hidden names are rejected");
		Check(ProjectCreationNameProblem(@"My Project") == nil, @"Ordinary names are accepted");
		Check([ProjectCreationBranchDirectoryName(@"feature/a/b") isEqual:@"feature-a-b"], @"Branch folders flatten slashes");

		// Worktrees layout from a clone: Name/<default branch>/, marked in config.
		NSError* error = nil;
		NSString* project = [parent stringByAppendingPathComponent:@"proj"];
		NSString* main = ProjectCreationCreate(parent, @"proj", ProjectCreationLayoutWorktrees, source, git, &error);
		Check([main isEqual:[project stringByAppendingPathComponent:@"trunk"]], [@"Clone is checked out under its default branch: " stringByAppendingString:main ?: error.localizedDescription]);
		Check([Contents(project) isEqual:@[@"trunk"]], @"No temporary folder is left in the project folder");
		Check([Git(git, main, @[@"config", @"textmate.layout"]) isEqual:@"worktrees"], @"Worktrees layout is recorded in the repository");
		NSDictionary* metadata = CommandPaletteWorktreeForPath(CommandPaletteWorktrees(@[main], git), main);
		Check(CommandPaletteUsesWorktreeLayout(metadata), @"Discovery recognises the created layout");
		Check([ProjectCreationImportPath(project) isEqual:main], @"Importing the project folder opens its main checkout");
		Check([ProjectCreationImportPath(main) isEqual:main], @"Importing a checkout opens it");

		// New worktrees go beside the main checkout.
		NSString* feature = ProjectCreationAddWorktree(main, @"feature/x", git, &error);
		Check([feature isEqual:[project stringByAppendingPathComponent:@"feature-x"]], [@"New branch worktree: " stringByAppendingString:feature ?: error.localizedDescription]);
		Check([Git(git, feature, @[@"rev-parse", @"--abbrev-ref", @"HEAD"]) isEqual:@"feature/x"], @"New branch is checked out");
		Check([Git(git, feature, @[@"rev-parse", @"HEAD"]) isEqual:Git(git, main, @[@"rev-parse", @"HEAD"])], @"New branch starts at the main checkout");
		NSString* topic = ProjectCreationAddWorktree(main, @"topic", git, &error);
		Check(topic != nil, [@"Remote branch worktree: " stringByAppendingString:error.localizedDescription ?: @""]);
		Check([Git(git, topic, @[@"rev-parse", @"--abbrev-ref", @"@{upstream}"]) isEqual:@"origin/topic"], @"Remote branches are tracked");
		Check([ProjectCreationImportPath(project) isEqual:main], @"Linked worktrees do not confuse importing");
		error = nil;
		Check(ProjectCreationAddWorktree(main, @"feature/x", git, &error) == nil && error, @"An existing worktree folder is not reused");
		error = nil;
		Check(ProjectCreationAddWorktree(main, @"bad..name", git, &error) == nil && error, @"Invalid branch names are rejected");
		Check(ProjectCreationAddWorktree(main, @"-f", git, nil) == nil, @"Branch names cannot be options");

		// Single checkout layout from git init.
		NSString* plain = ProjectCreationCreate(parent, @"plain", ProjectCreationLayoutPlain, @"", git, &error);
		Check([plain isEqual:[parent stringByAppendingPathComponent:@"plain"]], [@"Plain project is the repository: " stringByAppendingString:plain ?: error.localizedDescription]);
		Check([fm fileExistsAtPath:[plain stringByAppendingPathComponent:@".git"]], @"Plain project is initialised");
		Check(!CommandPaletteUsesWorktreeLayout(CommandPaletteWorktreeForPath(CommandPaletteWorktrees(@[plain], git), plain)), @"Plain projects do not offer worktrees");

		// Worktrees layout from git init uses whatever default branch Git chose.
		NSString* fresh = ProjectCreationCreate(parent, @"fresh", ProjectCreationLayoutWorktrees, nil, git, &error);
		Check([fresh.stringByDeletingLastPathComponent isEqual:[parent stringByAppendingPathComponent:@"fresh"]], [@"New repository is nested in its project folder: " stringByAppendingString:fresh ?: error.localizedDescription]);
		Check([fresh.lastPathComponent isEqual:ProjectCreationBranchDirectoryName(Git(git, fresh, @[@"symbolic-ref", @"--short", @"HEAD"]))], @"New repository folder is named after its branch");

		// Failures leave nothing behind and never touch existing folders.
		error = nil;
		Check(ProjectCreationCreate(parent, @"proj", ProjectCreationLayoutPlain, @"", git, &error) == nil && error, @"Existing projects are not overwritten");
		Check([Contents(project) isEqual:(@[@"feature-x", @"topic", @"trunk"])], @"Existing project is untouched");
		error = nil;
		Check(ProjectCreationCreate(parent, @"broken", ProjectCreationLayoutWorktrees, [temporary stringByAppendingPathComponent:@"missing"], git, &error) == nil && error.localizedDescription.length, @"Failed clones report Git's error");
		Check(![fm fileExistsAtPath:[parent stringByAppendingPathComponent:@"broken"]], @"Failed clones are cleaned up");
		Check(ProjectCreationCreate([temporary stringByAppendingPathComponent:@"nowhere"], @"x", ProjectCreationLayoutPlain, @"", git, nil) == nil, @"A missing location is reported");

		// A lone repository in an ordinary folder is not a worktree container.
		NSString* vendor = [temporary stringByAppendingPathComponent:@"vendor"];
		NSString* library = [vendor stringByAppendingPathComponent:@"library"];
		[fm createDirectoryAtPath:library withIntermediateDirectories:YES attributes:nil error:nil];
		Git(git, library, @[@"init", @"-b", @"main"]);
		Check([ProjectCreationImportPath(vendor) isEqual:vendor], @"Importing a folder with one unrelated repository opens the folder");

		// A hand-made container without the marker is recognised by its linked worktree.
		NSString* hand = [temporary stringByAppendingPathComponent:@"hand"];
		NSString* handMain = [hand stringByAppendingPathComponent:@"main"];
		[fm createDirectoryAtPath:handMain withIntermediateDirectories:YES attributes:nil error:nil];
		Git(git, handMain, @[@"init", @"-b", @"main"]);
		Git(git, handMain, @[@"commit", @"--allow-empty", @"-m", @"Initial"]);
		Check([ProjectCreationImportPath(hand) isEqual:hand], @"Without a marker or worktrees the folder itself is opened");
		Git(git, handMain, @[@"worktree", @"add", @"-b", @"other", [hand stringByAppendingPathComponent:@"other"]]);
		Check([ProjectCreationImportPath(hand) isEqual:handMain], @"A linked sibling worktree identifies the container");

		NSString* empty = [temporary stringByAppendingPathComponent:@"empty"];
		[fm createDirectoryAtPath:empty withIntermediateDirectories:YES attributes:nil error:nil];
		Check([ProjectCreationImportPath(empty) isEqual:empty], @"Ordinary folders import as themselves");

		[fm removeItemAtPath:temporary error:nil];
		puts("Project creation checks passed.");
	}
	return 0;
}
