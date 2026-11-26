#import "../src/WorktreeProject.h"
#include <regexp/format_string.h>

static void worktree_test_git (NSString* directory, NSArray<NSString*>* arguments)
{
	NSTask* task = [[NSTask alloc] init];
	task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/git"];
	task.arguments = [@[@"-C", directory, @"-c", @"user.name=TextMate Tests", @"-c", @"user.email=tests@example.invalid", @"-c", @"commit.gpgsign=false", @"-c", @"core.hooksPath=/dev/null"] arrayByAddingObjectsFromArray:arguments];
	task.environment = @{ @"PATH": @"/usr/bin:/bin", @"HOME": NSTemporaryDirectory() };
	task.standardInput = [NSFileHandle fileHandleWithNullDevice];
	task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
	task.standardError = [NSFileHandle fileHandleWithNullDevice];
	OAK_ASSERT([task launchAndReturnError:nil]);
	[task waitUntilExit];
	OAK_ASSERT_EQ(task.terminationStatus, 0);
}

static NSString* worktree_test_directory ()
{
	NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"TextMate Worktree " stringByAppendingString:NSUUID.UUID.UUIDString]];
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
	return directory.stringByResolvingSymlinksInPath;
}

static NSString* worktree_test_repository (NSString* container, NSString* name)
{
	NSString* main = [container stringByAppendingPathComponent:name];
	OAK_ASSERT([NSFileManager.defaultManager createDirectoryAtPath:main withIntermediateDirectories:YES attributes:nil error:nil]);
	worktree_test_git(main, @[@"init", @"--quiet", @"-b", @"main"]);
	worktree_test_git(main, @[@"commit", @"--quiet", @"--allow-empty", @"-m", @"initial"]);
	return main;
}

void test_worktree_project_name_from_layout_marker ()
{
	NSString* container = [worktree_test_directory() stringByAppendingPathComponent:@"widget"];
	NSString* main = worktree_test_repository(container, @"main");
	OAK_ASSERT(WorktreeProjectName(main) == nil);

	worktree_test_git(main, @[@"config", @"textmate.layout", @"worktrees"]);
	NSString* feature = [container stringByAppendingPathComponent:@"feature-x"];
	worktree_test_git(main, @[@"worktree", @"add", @"--quiet", @"-b", @"feature/x", feature]);

	OAK_ASSERT_EQ(to_s(WorktreeProjectName(main)), "widget");
	OAK_ASSERT_EQ(to_s(WorktreeProjectName(feature)), "widget");
	OAK_ASSERT(WorktreeProjectName([main stringByAppendingPathComponent:@"sub"]) == nil);
	[NSFileManager.defaultManager removeItemAtPath:container.stringByDeletingLastPathComponent error:nil];
}

void test_worktree_project_name_from_origin_name ()
{
	NSString* container = [worktree_test_directory() stringByAppendingPathComponent:@"TextMate"];
	NSString* main = worktree_test_repository(container, @"develop");
	worktree_test_git(main, @[@"remote", @"add", @"origin", @"git@github.com:someone/textmate.git"]);
	NSString* feature = [container stringByAppendingPathComponent:@"feature"];
	worktree_test_git(main, @[@"worktree", @"add", @"--quiet", @"-b", @"feature", feature]);

	OAK_ASSERT_EQ(to_s(WorktreeProjectName(main)), "TextMate");
	OAK_ASSERT_EQ(to_s(WorktreeProjectName(feature)), "TextMate");
	[NSFileManager.defaultManager removeItemAtPath:container.stringByDeletingLastPathComponent error:nil];
}

void test_worktree_project_name_ignores_plain_repositories ()
{
	NSString* parent = worktree_test_directory();
	NSString* repo = worktree_test_repository(parent, @"textmate");
	worktree_test_git(repo, @[@"remote", @"add", @"origin", @"https://github.com/someone/textmate"]);
	OAK_ASSERT(WorktreeProjectName(repo) == nil);
	OAK_ASSERT(WorktreeProjectName(parent) == nil);
	OAK_ASSERT(WorktreeProjectName(nil) == nil);

	// A worktree placed outside the main checkout's folder is not part of a container.
	NSString* elsewhere = [worktree_test_directory() stringByAppendingPathComponent:@"other"];
	worktree_test_git(repo, @[@"config", @"textmate.layout", @"worktrees"]);
	worktree_test_git(repo, @[@"worktree", @"add", @"--quiet", @"-b", @"other", elsewhere]);
	OAK_ASSERT(WorktreeProjectName(elsewhere) == nil);
	[NSFileManager.defaultManager removeItemAtPath:parent error:nil];
	[NSFileManager.defaultManager removeItemAtPath:elsewhere.stringByDeletingLastPathComponent error:nil];
}

void test_worktree_project_window_title_format ()
{
	std::string const format = "${projectDirectory:+ — ${projectName:+$projectName }${projectDirectory/^.*\\///}}";
	OAK_ASSERT_EQ(format_string::expand(format, { { "projectDirectory", "/Users/me/textmate/feature-x" }, { "projectName", "textmate" } }), " — textmate feature-x");
	OAK_ASSERT_EQ(format_string::expand(format, { { "projectDirectory", "/Users/me/widget" } }), " — widget");
}
