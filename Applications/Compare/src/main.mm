#import <Cocoa/Cocoa.h>
#import "CompareWindowController.h"
#import "compare_url.h"
#import "compare_syntax.h"
#import "compare_menu.h"
#import "CompareSettings.h"
#import "CompareChooser.h"
#import <mach-o/dyld.h>
#import <OakSystem/application.h>
#import <Preferences/Keys.h>
#import <scm/drivers/api.h>
#import <settings/settings.h>
#import <io/path.h>
#import <ns/ns.h>
#import <oak/oak.h>

static BOOL IsDirectory (NSString* path)
{
	BOOL isDirectory = NO;
	return [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory;
}

@interface CompareAppController : NSObject <NSApplicationDelegate>
@end

@implementation CompareAppController
{
	NSMutableArray<CompareWindowController*>* _controllers;
	CompareChooserWindowController* _chooser;
	BOOL _receivedRequest;
}

- (instancetype)init
{
	if(self = [super init])
		_controllers = [NSMutableArray array];
	return self;
}

- (void)applicationWillFinishLaunching:(NSNotification*)notification
{
	[self createMenu];
	[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowWillClose:) name:NSWindowWillCloseNotification object:nil];
}

// Started with nothing to compare (tm-compare without arguments, or the app
// opened by itself): ask for what to compare.
- (void)applicationDidFinishLaunching:(NSNotification*)notification
{
	if(![notification.userInfo[NSApplicationLaunchIsDefaultLaunchKey] boolValue])
		return; // launched to open a request
	dispatch_async(dispatch_get_main_queue(), ^{
		if(!_receivedRequest && !_controllers.count)
			[self newComparison:self];
	});
}

// Clicking the Dock icon with no windows open.
- (BOOL)applicationShouldHandleReopen:(NSApplication*)sender hasVisibleWindows:(BOOL)visible
{
	if(!visible)
		[self newComparison:self];
	return YES;
}

- (IBAction)newComparison:(id)sender
{
	if(!_chooser)
	{
		_chooser = [CompareChooserWindowController new];
		__weak CompareAppController* weakSelf = self;
		_chooser.compareHandler = ^(NSString* left, NSString* right){
			[weakSelf openComparisonWithLeft:left right:right focus:nil];
		};
	}
	[_chooser showWindow:self];
}

- (void)applicationWillTerminate:(NSNotification*)notification
{
	[_controllers makeObjectsPerformSelector:@selector(saveState)];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender
{
	return YES;
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication*)app
{
	return YES;
}

- (void)application:(NSApplication*)application openURLs:(NSArray<NSURL*>*)urls
{
	_receivedRequest = YES;
	for(NSURL* url in urls)
	{
		compare::request_t request;
		if(!compare::parse(url, &request))
		{
			NSLog(@"Compare: ignoring malformed request %@", url);
			continue;
		}
		[self openComparisonWithLeft:request.left.stringByStandardizingPath right:request.right.stringByStandardizingPath focus:request.focus];
	}
}

- (void)openComparisonWithLeft:(NSString*)left right:(NSString*)right focus:(NSString*)focus
{
	// Two folders, or two files.
	NSString* problem = nil;
	for(NSString* path in @[ left, right ])
	{
		if(!problem && ![NSFileManager.defaultManager fileExistsAtPath:path])
			problem = [NSString stringWithFormat:@"“%@” does not exist.", path.stringByAbbreviatingWithTildeInPath];
	}
	if(!problem && IsDirectory(left) != IsDirectory(right))
		problem = [NSString stringWithFormat:@"“%@” is a %@ and “%@” is a %@. Compare two folders, or two files.", left.lastPathComponent, IsDirectory(left) ? @"folder" : @"file", right.lastPathComponent, IsDirectory(right) ? @"folder" : @"file"];
	if(problem)
	{
		NSAlert* alert = [NSAlert new];
		alert.messageText     = @"These can’t be compared.";
		alert.informativeText = problem;
		[alert runModal];
		if(!_controllers.count)
			[NSApp terminate:self];
		return;
	}
	if(!IsDirectory(left))
		focus = nil; // a folder below the roots: none for files

	for(CompareWindowController* controller in _controllers)
	{
		if([controller.leftPath isEqualToString:left] && [controller.rightPath isEqualToString:right])
		{
			controller.focus = focus;
			[controller showWindow:self];
			return;
		}
	}

	CompareWindowController* controller = [[CompareWindowController alloc] initWithLeftPath:left rightPath:right focus:focus];
	[_controllers addObject:controller];
	if(NSWindow* previous = NSApp.keyWindow)
		[controller.window setFrameTopLeftPoint:[controller.window cascadeTopLeftFromPoint:NSMakePoint(NSMinX(previous.frame), NSMaxY(previous.frame))]];
	[controller showWindow:self];
}

- (void)windowWillClose:(NSNotification*)notification
{
	// This observer may run before the window's own delegate (the controller)
	// hears of the close, so save its state here and release it only once
	// the close has finished.
	NSWindow* window = notification.object;
	for(CompareWindowController* controller in [_controllers copy])
	{
		if(controller.window != window)
			continue;
		[controller saveState];
		dispatch_async(dispatch_get_main_queue(), ^{
			[_controllers removeObject:controller];
		});
	}
}

- (IBAction)showSettings:(id)sender
{
	[CompareSettingsWindowController.sharedController showWindow:self];
}

- (void)createMenu
{
	NSMenu* menu = [NSMenu new];

	NSMenuItem* app = [NSMenuItem new];
	app.submenu = [NSMenu new];
	[app.submenu addItemWithTitle:@"Settings…" action:@selector(showSettings:) keyEquivalent:@","];
	[app.submenu addItem:NSMenuItem.separatorItem];
	[app.submenu addItemWithTitle:@"Hide Compare" action:@selector(hide:) keyEquivalent:@"h"];
	[app.submenu addItem:NSMenuItem.separatorItem];
	[app.submenu addItemWithTitle:@"Quit Compare" action:@selector(terminate:) keyEquivalent:@"q"];
	[menu addItem:app];

	NSMenuItem* file = [NSMenuItem new];
	file.submenu = [[NSMenu alloc] initWithTitle:@"File"];
	[file.submenu addItemWithTitle:@"New Comparison…" action:@selector(newComparison:) keyEquivalent:@"n"];
	[file.submenu addItemWithTitle:@"Open File Comparison" action:@selector(openSelectedFiles:) keyEquivalent:@"o"];
	[file.submenu addItemWithTitle:@"Edit in TextMate" action:@selector(editInTextMate:) keyEquivalent:@"e"];
	[file.submenu addItemWithTitle:@"Compare Again" action:@selector(refresh:) keyEquivalent:@"r"];
	[file.submenu addItem:NSMenuItem.separatorItem];
	[file.submenu addItemWithTitle:@"Close Tab" action:@selector(closeTab:) keyEquivalent:@"w"];
	[file.submenu addItem:NSMenuItem.separatorItem];
	[file.submenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"]; // as Compare → Quit Compare
	[menu addItem:file];

	NSMenuItem* edit = [NSMenuItem new];
	edit.submenu = [[NSMenu alloc] initWithTitle:@"Edit"];
	[edit.submenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
	[edit.submenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
	[edit.submenu addItem:NSMenuItem.separatorItem];
	[edit.submenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
	[edit.submenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
	[edit.submenu addItem:NSMenuItem.separatorItem];
	NSMenuItem* find = [edit.submenu addItemWithTitle:@"Find" action:NULL keyEquivalent:@""];
	find.submenu = compare::find_menu();
	[edit.submenu addItem:NSMenuItem.separatorItem];
	for(NSArray* entry in @[ @[ @"Copy to the Right", NSStringFromSelector(@selector(copyToRight:)), @(NSRightArrowFunctionKey) ], @[ @"Copy to the Left", NSStringFromSelector(@selector(copyToLeft:)), @(NSLeftArrowFunctionKey) ] ])
	{
		NSMenuItem* item = [edit.submenu addItemWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:[NSString stringWithFormat:@"%C", (unichar)[entry[2] unsignedShortValue]]];
		item.keyEquivalentModifierMask = NSEventModifierFlagCommand|NSEventModifierFlagOption;
	}
	[menu addItem:edit];

	NSMenuItem* view = [NSMenuItem new];
	view.submenu = compare::view_menu();
	[menu addItem:view];

	NSMenuItem* go = [NSMenuItem new];
	go.submenu = [[NSMenu alloc] initWithTitle:@"Go"];
	NSMenuItem* next = [go.submenu addItemWithTitle:@"Next Change" action:@selector(nextChange:) keyEquivalent:[NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey]];
	next.keyEquivalentModifierMask = NSEventModifierFlagCommand|NSEventModifierFlagControl;
	NSMenuItem* previous = [go.submenu addItemWithTitle:@"Previous Change" action:@selector(previousChange:) keyEquivalent:[NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey]];
	previous.keyEquivalentModifierMask = NSEventModifierFlagCommand|NSEventModifierFlagControl;
	[menu addItem:go];

	NSMenuItem* window = [NSMenuItem new];
	window.submenu = [[NSMenu alloc] initWithTitle:@"Window"];
	[window.submenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
	[window.submenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
	[window.submenu addItem:NSMenuItem.separatorItem];
	[window.submenu addItemWithTitle:@"Select Next Tab" action:@selector(selectNextTab:) keyEquivalent:@"}"];
	[window.submenu addItemWithTitle:@"Select Previous Tab" action:@selector(selectPreviousTab:) keyEquivalent:@"{"];
	[menu addItem:window];

	NSApp.mainMenu = menu;
	NSApp.windowsMenu = window.submenu;
}
@end

int main (int argc, char const* argv[])
{
	@autoreleasepool
	{
		// Share TextMate’s support folder, settings and preferences, as
		// ThemeEditor does, so Git is found the same way TextMate finds it.
		oak::application_t application(argc, argv);
		oak::application_t::set_name("TextMate");
		uint32_t length = 0;
		_NSGetExecutablePath(nullptr, &length);
		std::vector<char> executablePath(length);
		_NSGetExecutablePath(executablePath.data(), &length);
		NSString* executable = to_ns(path::resolve(executablePath.data()));
		NSBundle* bundle = [NSBundle bundleWithPath:executable.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent];
		NSBundle* containingBundle = [NSBundle bundleWithPath:bundle.bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent];
		if([containingBundle.bundleIdentifier hasPrefix:@"com.macromates.TextMate"])
			bundle = containingBundle;
		if(bundle.bundleIdentifier)
			oak::application_t::set_path(to_s(bundle.bundlePath));
		else
			bundle = NSBundle.mainBundle;
		if(bundle.bundleIdentifier && ![bundle.bundleIdentifier isEqualToString:NSBundle.mainBundle.bundleIdentifier])
			[NSUserDefaults.standardUserDefaults addSuiteNamed:bundle.bundleIdentifier];
		RegisterDefaults();
		settings_t::set_global_settings_path(oak::application_t::support("Global.tmProperties"));
		if(NSString* defaults = [bundle pathForResource:@"Default" ofType:@"tmProperties"])
			settings_t::set_default_settings_path(to_s(defaults));

		// Used by the compare-launch test: reaching this point means dyld loaded
		// every library under the app's real signature and entitlements.
		if(argc == 2 && strcmp(argv[1], "--check-launch") == 0)
		{
			fprintf(stdout, "Compare launched\n");
			return 0;
		}

		// The bundle catalogue (grammars, themes) for syntax highlighting.
		compare::load_bundle_index();

		std::string git = scm::find_executable("git", "TM_GIT");
		CompareWindowController.gitExecutable = git == NULL_STR ? nil : to_ns(git);

		[NSApplication sharedApplication];
		[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
		CompareAppController* controller = [CompareAppController new];
		NSApp.delegate = controller;
		[NSApp run];
	}
	return 0;
}
