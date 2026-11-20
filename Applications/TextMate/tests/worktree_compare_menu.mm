#import <Cocoa/Cocoa.h>
#import "../src/WorktreeCompareMenu.h"
#import "../src/CommandPaletteProjects.h"
#import "../../Compare/src/compare_url.h"

// Drives Text → Compare To's menu logic against a real repository: hidden
// without other worktrees, listed as “folder (branch)”, the URL it opens, and
// following worktrees added and removed by Git (as from TextMate's terminal,
// so without the app becoming active).

static int Failures = 0;
#define CHECK(expr) do { if(!(expr)) { fprintf(stderr, "%s:%d: Assertion failed: %s\n", __FILE__, __LINE__, #expr); ++Failures; } } while(false)

static NSString* Git;

static BOOL RunGit (NSString* directory, NSArray<NSString*>* arguments)
{
	NSTask* task = [NSTask new];
	task.executableURL = [NSURL fileURLWithPath:Git];
	task.arguments = [@[ @"-C", directory, @"-c", @"user.name=Test", @"-c", @"user.email=test@example.invalid", @"-c", @"commit.gpgsign=false", @"-c", @"core.hooksPath=/dev/null" ] arrayByAddingObjectsFromArray:arguments];
	task.standardOutput = task.standardError = NSFileHandle.fileHandleWithNullDevice;
	if(![task launchAndReturnError:nil])
		return NO;
	[task waitUntilExit];
	return task.terminationStatus == 0;
}

static BOOL WaitUntil (BOOL (^condition)())
{
	NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:20];
	while(!condition() && deadline.timeIntervalSinceNow > 0)
		[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	return condition();
}

int main (int argc, char const* argv[])
{
	@autoreleasepool
	{
		if(argc != 2)
		{
			fprintf(stderr, "usage: %s <git>\n", argv[0]);
			return 2;
		}
		Git = @(argv[1]);
		[NSApplication sharedApplication];

		// Under a folder named “worktrees”: only the Git folder's own worktrees
		// folder may trigger a lookup, not every change below this path.
		NSString* base = [[NSTemporaryDirectory() stringByAppendingPathComponent:[@"worktree-compare-menu-" stringByAppendingString:NSUUID.UUID.UUIDString]] stringByAppendingPathComponent:@"worktrees"];
		NSString* main    = [base stringByAppendingPathComponent:@"main checkout"];
		NSString* feature = [base stringByAppendingPathComponent:@"feature-worktree"];
		NSString* third   = [base stringByAppendingPathComponent:@"third"];
		NSString* project = [main stringByAppendingPathComponent:@"sub/dir"];
		[NSFileManager.defaultManager createDirectoryAtPath:project withIntermediateDirectories:YES attributes:nil error:nil];
		[@"x\n" writeToFile:[project stringByAppendingPathComponent:@"file.txt"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
		CHECK(RunGit(main, @[ @"init", @"-q", @"-b", @"main" ]));
		CHECK(RunGit(main, @[ @"add", @"-A" ]));
		CHECK(RunGit(main, @[ @"commit", @"-q", @"-m", @"Initial" ]));

		WorktreeCompareMenu* menu = [WorktreeCompareMenu new];
		__block NSString* projectPath = project;
		NSMutableArray<NSURL*>* opened = [NSMutableArray array];
		menu.projectPathProvider = ^{ return projectPath; };
		menu.gitExecutable = Git;
		menu.openHandler = ^(NSURL* url){ [opened addObject:url]; };

		NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:@"Compare To" action:NULL keyEquivalent:@""];
		item.submenu = [[NSMenu alloc] initWithTitle:@"Compare To"];
		item.hidden = YES;
		menu.menuItem = item;

		// No other worktree: the item stays hidden once discovery has finished.
		CHECK(WaitUntil(^{ return (BOOL)(menu.otherWorktreePaths != nil); }));
		CHECK(menu.otherWorktreePaths.count == 0);
		[menu updateMenuItemVisibility];
		CHECK(item.hidden);
		[menu menuNeedsUpdate:item.submenu];
		CHECK(item.submenu.numberOfItems == 1 && [item.submenu itemAtIndex:0].action == NULL); // “No Other Worktrees”

		// Other Git activity (a commit) does not look the worktrees up again.
		NSUInteger lookups = menu.discoveryCount;
		CHECK(RunGit(main, @[ @"commit", @"-q", @"--allow-empty", @"-m", @"Activity" ]));
		for(NSDate* until = [NSDate dateWithTimeIntervalSinceNow:2.5]; until.timeIntervalSinceNow > 0; )
			[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
		CHECK(menu.discoveryCount == lookups);

		// A worktree added from a terminal shows the item, without activation.
		CHECK(RunGit(main, @[ @"worktree", @"add", @"-q", @"-b", @"feature", feature ]));
		CHECK(WaitUntil(^{ [menu updateMenuItemVisibility]; return (BOOL)!item.hidden; }));
		[menu menuNeedsUpdate:item.submenu];
		CHECK(item.submenu.numberOfItems == 1);
		NSMenuItem* entry = item.submenu.numberOfItems ? [item.submenu itemAtIndex:0] : nil;
		CHECK([entry.title isEqualToString:@"feature-worktree (feature)"]);

		// Choosing it opens the comparison of the two roots, on the project's folder.
		[NSApp sendAction:entry.action to:entry.target from:entry];
		CHECK(opened.count == 1);
		compare::request_t request;
		CHECK(opened.count && compare::parse(opened.lastObject, &request));
		CHECK([request.left isEqualToString:CommandPaletteCanonicalPath(main)]);
		CHECK([request.right isEqualToString:CommandPaletteCanonicalPath(feature)]);
		CHECK([request.focus isEqualToString:@"sub/dir"]);

		// More worktrees are listed by folder name.
		CHECK(RunGit(main, @[ @"worktree", @"add", @"-q", @"--detach", third ]));
		CHECK(WaitUntil(^{ return (BOOL)(menu.otherWorktreePaths.count == 2); }));
		[menu menuNeedsUpdate:item.submenu];
		NSArray* titles = [item.submenu.itemArray valueForKey:@"title"];
		CHECK(titles.count == 2 && [titles[0] isEqualToString:@"feature-worktree (feature)"] && [titles[1] hasPrefix:@"third (detached "]);

		// From a linked worktree, the main checkout is the other one.
		projectPath = feature;
		CHECK(WaitUntil(^{ [menu updateMenuItemVisibility]; return (BOOL)(menu.otherWorktreePaths.count == 2); }));
		CHECK([menu.otherWorktreePaths containsObject:CommandPaletteCanonicalPath(main)]);
		projectPath = project;
		[menu updateMenuItemVisibility];

		// Removing the worktrees hides the item again.
		CHECK(RunGit(main, @[ @"worktree", @"remove", @"--force", feature ]));
		CHECK(RunGit(main, @[ @"worktree", @"remove", @"--force", third ]));
		CHECK(WaitUntil(^{ [menu updateMenuItemVisibility]; return (BOOL)item.hidden; }));

		// A window without a project hides it.
		CHECK(RunGit(main, @[ @"worktree", @"add", @"-q", @"-b", @"again", feature ]));
		CHECK(WaitUntil(^{ [menu updateMenuItemVisibility]; return (BOOL)!item.hidden; }));
		projectPath = nil;
		[menu updateMenuItemVisibility];
		CHECK(item.hidden);

		[NSFileManager.defaultManager removeItemAtPath:base.stringByDeletingLastPathComponent error:nil];
		if(Failures)
			fprintf(stderr, "worktree-compare-menu: %d assertion(s) failed\n", Failures);
		else
			fprintf(stdout, "worktree-compare-menu: all checks passed\n");
		return Failures ? 1 : 0;
	}
}
