#import "WorktreeCompareMenu.h"
#import "CommandPaletteProjects.h"
#import "../../Compare/src/compare_url.h"
#import "../../Compare/src/compare_watch.h"
#import <DocumentWindow/DocumentWindowController.h>
#import <scm/drivers/api.h>
#import <oak/oak.h>

// Cache entry for one project path:
//   root:   canonical root of the worktree containing the project
//   focus:  project path relative to root, or nil when they are equal
//   others: [{ path, branch }] for the repository's other worktrees
//   repository: the main checkout (or bare repository), whose Git folder lists the worktrees
static NSDictionary* WorktreeEntry (NSString* projectPath, NSDictionary<NSString*, NSDictionary*>* worktrees)
{
	NSDictionary* current = CommandPaletteWorktreeForPath(worktrees, projectPath);
	NSString* root = current[@"path"];
	if(!root)
		return @{ };

	NSMutableArray* others = [NSMutableArray array];
	for(NSString* path in current[@"relatedPaths"])
	{
		if(![path isEqualToString:root])
			[others addObject:@{ @"path": path, @"branch": worktrees[path][@"branchLabel"] ?: @"" }];
	}

	NSString* canonical = CommandPaletteCanonicalPath(projectPath);
	NSString* focus = canonical.length > root.length ? [canonical substringFromIndex:[root isEqualToString:@"/"] ? 1 : root.length + 1] : nil;
	NSMutableDictionary* entry = [@{ @"root": root, @"others": others } mutableCopy];
	entry[@"focus"]      = focus;
	entry[@"repository"] = current[@"repositoryPath"];
	return entry;
}

@implementation WorktreeCompareMenu
{
	NSMutableDictionary<NSString*, NSDictionary*>* _entries; // keyed by DocumentWindowController.projectPath
	NSMutableSet<NSString*>* _pending;
	NSString* _projectPath;
	dispatch_queue_t _queue;
	compare::folder_watch_t _watch;
	NSString* _watchedFolder;
}

+ (WorktreeCompareMenu*)sharedInstance
{
	static WorktreeCompareMenu* instance = [WorktreeCompareMenu new];
	return instance;
}

- (instancetype)init
{
	if(self = [super init])
	{
		_entries = [NSMutableDictionary dictionary];
		_pending = [NSMutableSet set];
		_queue   = dispatch_queue_create("com.macromates.TextMate.worktree-compare", DISPATCH_QUEUE_SERIAL);
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationDidBecomeActive:) name:NSApplicationDidBecomeActiveNotification object:NSApp];
	}
	return self;
}

- (NSString*)mainProjectPath
{
	id delegate = NSApp.mainWindow.delegate;
	return [delegate isKindOfClass:DocumentWindowController.class] ? [(DocumentWindowController*)delegate projectPath] : nil;
}

- (void)setMenuItem:(NSMenuItem*)menuItem
{
	_menuItem = menuItem;
	_menuItem.submenu.delegate = self;
	[self updateMenuItemVisibility];
}

- (void)updateMenuItemVisibility
{
	NSString* projectPath = self.mainProjectPath;
	if(projectPath != _projectPath && ![projectPath isEqualToString:_projectPath])
	{
		_projectPath = projectPath;
		if(projectPath && !_entries[projectPath])
			[self refreshProjectPath:projectPath];
		[self watchRepository:_entries[projectPath][@"repository"]];
	}
	BOOL hidden = !projectPath || [_entries[projectPath][@"others"] count] == 0;
	if(_menuItem.hidden != hidden)
		_menuItem.hidden = hidden;
}

- (void)applicationDidBecomeActive:(NSNotification*)notification
{
	// Worktrees are often added or removed from a terminal while TextMate is
	// in the background.
	if(NSString* projectPath = self.mainProjectPath)
		[self refreshProjectPath:projectPath];
}

- (void)refreshProjectPath:(NSString*)projectPath
{
	if([_pending containsObject:projectPath])
		return;
	[_pending addObject:projectPath];
	dispatch_async(_queue, ^{
		std::string git = scm::find_executable("git", "TM_GIT");
		NSDictionary* worktrees = CommandPaletteWorktrees(@[ projectPath ], git == NULL_STR ? nil : @(git.c_str()));
		NSDictionary* entry = WorktreeEntry(projectPath, worktrees);
		dispatch_async(dispatch_get_main_queue(), ^{
			[_pending removeObject:projectPath];
			_entries[projectPath] = entry;
			if([projectPath isEqualToString:self.mainProjectPath])
				[self watchRepository:entry[@"repository"]];
			[self updateMenuItemVisibility];
		});
	});
}

// Worktrees are added and removed in the repository's Git folder (often from
// TextMate's own terminal, so no activation happens): watch it while the main
// window's project belongs to that repository.
- (void)watchRepository:(NSString*)repository
{
	NSString* folder = nil;
	if(repository)
	{
		NSString* gitFolder = [repository stringByAppendingPathComponent:@".git"];
		BOOL isDirectory = NO;
		folder = [NSFileManager.defaultManager fileExistsAtPath:gitFolder isDirectory:&isDirectory] && isDirectory ? gitFolder : repository; // bare repository
	}
	if(folder == _watchedFolder || [folder isEqualToString:_watchedFolder])
		return;
	_watchedFolder = folder;
	if(!folder)
	{
		_watch.stop();
		return;
	}
	__weak WorktreeCompareMenu* weakSelf = self;
	_watch.start(@[ folder ], nil, 1.0, ^(NSArray<NSString*>* paths){
		for(NSString* path in paths)
		{
			if([path containsString:@"/worktrees"])
			{
				if(NSString* projectPath = weakSelf.mainProjectPath)
					[weakSelf refreshProjectPath:projectPath];
				break;
			}
		}
	});
}

// ==================
// = Compare To ▸ =
// ==================

- (BOOL)menuHasKeyEquivalent:(NSMenu*)menu forEvent:(NSEvent*)event target:(id*)target action:(SEL*)action
{
	return NO;
}

- (void)menuNeedsUpdate:(NSMenu*)menu
{
	[menu removeAllItems];
	NSString* projectPath = self.mainProjectPath;
	NSDictionary* entry = projectPath ? _entries[projectPath] : nil;
	NSArray* others = [entry[@"others"] sortedArrayUsingDescriptors:@[ [NSSortDescriptor sortDescriptorWithKey:@"path.lastPathComponent" ascending:YES selector:@selector(localizedStandardCompare:)] ]];
	for(NSDictionary* worktree in others)
	{
		NSString* path   = worktree[@"path"];
		NSString* branch = worktree[@"branch"];
		NSString* title  = branch.length ? [NSString stringWithFormat:@"%@ (%@)", path.lastPathComponent, branch] : path.lastPathComponent;
		NSMenuItem* item = [menu addItemWithTitle:title action:@selector(compareToWorktree:) keyEquivalent:@""];
		item.target            = self;
		item.representedObject = @{ @"left": entry[@"root"], @"right": path, @"focus": entry[@"focus"] ?: @"" };
		item.toolTip           = path.stringByAbbreviatingWithTildeInPath;
	}
	if(!others.count)
		[menu addItemWithTitle:@"No Other Worktrees" action:NULL keyEquivalent:@""];

	// Pick up worktrees added since the cache was filled, for next time.
	if(projectPath)
		[self refreshProjectPath:projectPath];
}

- (IBAction)compareToWorktree:(id)sender
{
	NSDictionary* request = [sender representedObject];
	NSURL* url = compare::url(request[@"left"], request[@"right"], request[@"focus"]);
	if(!url)
		return;

	NSURL* app = [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Contents/Helpers/Compare.app" isDirectory:YES];
	NSWorkspaceOpenConfiguration* configuration = [NSWorkspaceOpenConfiguration configuration];
	configuration.activates = YES;
	[NSWorkspace.sharedWorkspace openURLs:@[ url ] withApplicationAtURL:app configuration:configuration completionHandler:^(NSRunningApplication* runningApp, NSError* error) {
		if(error)
		{
			dispatch_async(dispatch_get_main_queue(), ^{
				[NSApp presentError:error];
			});
		}
	}];
}
@end
