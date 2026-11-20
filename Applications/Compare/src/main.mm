#import <Cocoa/Cocoa.h>
#import "CompareWindowController.h"
#import "compare_url.h"

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
	for(NSString* path in @[ left, right ])
	{
		if(!IsDirectory(path))
		{
			NSAlert* alert = [NSAlert new];
			alert.messageText     = @"The folder can’t be compared.";
			alert.informativeText = [NSString stringWithFormat:@"“%@” does not exist or is not a folder.", path.stringByAbbreviatingWithTildeInPath];
			[alert runModal];
			if(!_controllers.count)
				[NSApp terminate:self];
			return;
		}
	}

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
	NSWindow* window = notification.object;
	for(CompareWindowController* controller in [_controllers copy])
	{
		if(controller.window == window)
			[_controllers removeObject:controller];
	}
}

- (void)createMenu
{
	NSMenu* menu = [NSMenu new];

	NSMenuItem* app = [NSMenuItem new];
	app.submenu = [NSMenu new];
	[app.submenu addItemWithTitle:@"Hide Compare" action:@selector(hide:) keyEquivalent:@"h"];
	[app.submenu addItem:NSMenuItem.separatorItem];
	[app.submenu addItemWithTitle:@"Quit Compare" action:@selector(terminate:) keyEquivalent:@"q"];
	[menu addItem:app];

	NSMenuItem* file = [NSMenuItem new];
	file.submenu = [[NSMenu alloc] initWithTitle:@"File"];
	[file.submenu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
	[menu addItem:file];

	NSMenuItem* edit = [NSMenuItem new];
	edit.submenu = [[NSMenu alloc] initWithTitle:@"Edit"];
	[edit.submenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
	[edit.submenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
	[menu addItem:edit];

	NSMenuItem* window = [NSMenuItem new];
	window.submenu = [[NSMenu alloc] initWithTitle:@"Window"];
	[window.submenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
	[window.submenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
	[menu addItem:window];

	NSApp.mainMenu = menu;
	NSApp.windowsMenu = window.submenu;
}
@end

int main (int argc, char const* argv[])
{
	@autoreleasepool
	{
		[NSApplication sharedApplication];
		[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
		CompareAppController* controller = [CompareAppController new];
		NSApp.delegate = controller;
		[NSApp run];
	}
	return 0;
}
